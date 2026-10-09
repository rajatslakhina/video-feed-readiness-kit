/// The orchestrator: owns feed state, asks the pure planner for the desired
/// readiness, and drives the ports toward it.
///
/// Concurrency model (the part that has to survive review):
/// - All state lives in this actor. `prepare` and `fetch` run in child
///   `Task`s, so a slow prepare never blocks a swipe and prefetches overlap.
/// - Every port completion re-enters the actor and is checked against the
///   *current* state (lease identity, fetch token) before it is applied.
///   Nothing assumes the world is unchanged across an `await`.
/// - **Control commands are ordered.** `play`, `pause` and `release` go
///   through one FIFO chain, so the port sees them in the order the engine
///   decided them. Without that, `pause(B)` can overtake `play(B)` and two
///   clips end up playing at once, or `play(L)` lands after `release(L)`.
/// - **Whoever finishes last releases.** If the user swipes away from an
///   item while its decoder is still preparing, the lease is marked
///   `releaseWhenPrepared` and its slot stays occupied until the prepare
///   finishes and the port has released it. Freeing the slot early is the
///   classic fling bug: the pool reports a free decoder that the hardware
///   is still allocating, the next prepare over-commits, and the port
///   receives a release for a player it has not finished creating.
/// - A slot is returned to the pool only after `PlayerPort.release`
///   completes, so `decodersInUse` is what the hardware actually holds.
/// - **Make before break.** When the quality cap changes the rendition of
///   the clip on screen, the old decoder keeps playing until the new one is
///   ready; then the engine pauses the old, plays the new, and releases the
///   old. If the pool is full, the lowest-priority prepared decoder is
///   pre-empted to make room; only with a single-decoder budget does the
///   engine fall back to break-before-make (there is no room for two).
public actor FeedEngine {
    public struct Configuration: Sendable {
        public let decoderCapacity: Int
        public let cacheBudgetBytes: Int64
        public let ladder: QualityLadder.Configuration
        public let startLevel: Int
        public let skipThreshold: Double

        public init(decoderCapacity: Int = 4,
                    cacheBudgetBytes: Int64 = 64 * 1_024 * 1_024,
                    ladder: QualityLadder.Configuration = .init(),
                    startLevel: Int = 0,
                    skipThreshold: Double = 0.7) {
            self.decoderCapacity = min(max(0, decoderCapacity), DecoderPool.maximumCapacity)
            self.cacheBudgetBytes = max(0, cacheBudgetBytes)
            self.ladder = ladder
            self.startLevel = startLevel
            self.skipThreshold = skipThreshold.sanitized(in: 0 ... 1, fallback: 0.7)
        }
    }

    public struct Stats: Sendable, Equatable {
        public var reconciles = 0
        public var preparesStarted = 0
        public var preparesFailed = 0
        /// Releases that waited for an in-flight prepare to finish first.
        public var deferredReleases = 0
        public var releasesCompleted = 0
        public var playbackStarts = 0
        public var pausesSent = 0
        /// Rendition switches of the clip on screen done make-before-break.
        public var handOffs = 0
        /// Prepared decoders released to free a slot for a hand-off.
        public var preemptions = 0
        /// Hand-offs done break-before-make because the budget has one slot.
        public var breakBeforeMakeFallbacks = 0
        /// Times a planned decoder could not be acquired (pool full).
        public var decoderBusy = 0
        public var peakDecodersInUse = 0
        public var prefetchesStarted = 0
        public var prefetchesCancelled = 0
        public var prefetchesFailed = 0
        public var staleFetchCompletions = 0
        /// Reservation attempts the cache refused. A refused request is
        /// retried on the next re-plan, so this counts attempts, not clips.
        public var cacheRefusals = 0
        public var evictions = 0
        public var bytesFetched: Int64 = 0
        public var bytesCancelled: Int64 = 0
        public var qualityUps = 0
        public var qualityDowns = 0
        public init() {}
    }

    public enum DecoderStatus: String, Sendable {
        case idle, preparing, ready, releasing, playing
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let index: Int
        public let item: ItemID
        public let tier: ReadinessTier
        public let decoder: DecoderStatus
        /// The rendition this row's decoder actually holds (the playing one
        /// during a hand-off), or the planned one when it holds none.
        public let rendition: String
        /// The rendition the current plan wants. Differs from `rendition`
        /// only while a switch is in progress.
        public let plannedRendition: String
        /// Bytes delivered for this row's `rendition` (other renditions and
        /// in-flight reservations excluded).
        public let cachedBytes: Int64
        /// Seconds of media those bytes hold at `rendition`'s bitrate.
        public let cachedSeconds: Double
        public var id: Int { index }
    }

    public struct Snapshot: Sendable, Equatable {
        public let cursor: Int?
        public let itemCount: Int
        public let conditions: DeviceConditions
        public let shape: WindowShape
        /// Seconds per clip new prefetches use right now (shortened when the
        /// skip model predicts a skip; 0 offline).
        public let prefetchSecondsInUse: Double
        public let skipThreshold: Double
        public let qualityLevel: Int
        public let qualityCapKbps: Int
        public let skipProbability: Double
        public let decoderCapacity: Int
        public let decodersInUse: Int
        /// Bytes delivered to the cache.
        public let cacheBytes: Int64
        /// Bytes reserved for fetches still in flight.
        public let cacheReservedBytes: Int64
        public let cacheBudgetBytes: Int64
        public let rows: [Row]
        public let diagnostics: [PlanDiagnostic]
        public let stats: Stats
        public let pending: Int
    }

    /// Deliberate bugs, compiled in but reachable only through the internal
    /// initialiser. Each one disables exactly one safeguard so the tests can
    /// prove the check guarding it really fails without it.
    struct FaultInjection: OptionSet, Sendable {
        let rawValue: Int
        /// Free the slot and release the player while it is still preparing.
        static let releaseWhilePreparing = FaultInjection(rawValue: 1 << 0)
        /// Send play/pause/release from independent tasks (no ordering).
        static let unorderedPortCommands = FaultInjection(rawValue: 1 << 1)
        /// Apply a fetch completion without checking its token.
        static let acceptStaleFetchCompletions = FaultInjection(rawValue: 1 << 2)
        /// Release the playing decoder before its replacement is ready.
        static let breakBeforeMake = FaultInjection(rawValue: 1 << 3)
        /// Retry a failed prepare on the very next re-plan.
        static let noFailureSuppression = FaultInjection(rawValue: 1 << 4)
        /// Cancel the download of the clip the user just landed on.
        static let cancelFetchesOnLanding = FaultInjection(rawValue: 1 << 5)
        /// Never pre-empt a prepared decoder (or fall back) to unblock a hand-off.
        static let noHandOffPreemption = FaultInjection(rawValue: 1 << 6)
        /// Forget to return a slot to the pool after a release (a book-keeping bug
        /// only `invariantViolations()` can see).
        static let forgetPoolRelease = FaultInjection(rawValue: 1 << 7)
    }

    private enum DecoderState { case preparing, ready }

    private struct Held {
        let lease: DecoderLease
        var state: DecoderState
        var releaseWhenPrepared: Bool
    }

    private struct InFlight {
        let token: UInt64
        let committedBefore: Int64
        let task: Task<Void, Never>
    }

    private let player: any PlayerPort
    private let transport: any PrefetchTransport
    private let policy: any WindowPolicy
    private let planner = ReadinessPlanner()
    private let configuration: Configuration
    private let clock: any FeedClock
    let faults: FaultInjection

    private var items: [FeedItem]
    private var cursor: Int = 0
    private var conditions: DeviceConditions
    private var ladder: QualityLadder
    private var predictor: SkipPredictor
    private var pool: DecoderPool
    private var cache: RenditionCache
    private var held: [DecoderKey: Held] = [:]
    private var releasing: Set<DecoderLease> = []
    private var playingLease: DecoderLease?
    private var inFlight: [CacheKey: InFlight] = [:]
    private var nextToken: UInt64 = 1
    private var lastPlan: ReadinessPlan = .empty
    private var lastShape: WindowShape = .closed
    private var stats = Stats()
    private var pending = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Keys whose prepare failed. Not retried until the next external event
    /// (swipe, condition change, new items), so a port that always fails
    /// cannot drive a prepare -> fail -> release -> re-plan hot loop.
    private var suppressed: Set<DecoderKey> = []
    /// Tail of the FIFO chain that carries play/pause/release.
    private var controlTail: Task<Void, Never>?

    public init(items: [FeedItem],
                conditions: DeviceConditions = .ideal,
                configuration: Configuration = .init(),
                player: any PlayerPort,
                transport: any PrefetchTransport,
                policy: any WindowPolicy = DefaultWindowPolicy(),
                predictor: SkipPredictor = SkipPredictor(),
                clock: any FeedClock = SystemFeedClock()) {
        self.init(items: items, conditions: conditions, configuration: configuration, player: player,
                  transport: transport, policy: policy, predictor: predictor, clock: clock, faults: [])
    }

    init(items: [FeedItem], conditions: DeviceConditions, configuration: Configuration,
         player: any PlayerPort, transport: any PrefetchTransport, policy: any WindowPolicy,
         predictor: SkipPredictor, clock: any FeedClock, faults: FaultInjection) {
        self.items = items
        self.conditions = conditions
        self.configuration = configuration
        self.player = player
        self.transport = transport
        self.policy = policy
        self.predictor = predictor
        self.ladder = QualityLadder(configuration: configuration.ladder, startLevel: configuration.startLevel)
        self.pool = DecoderPool(capacity: configuration.decoderCapacity)
        self.cache = RenditionCache(budgetBytes: configuration.cacheBudgetBytes)
        self.clock = clock
        self.faults = faults
    }

    // MARK: - Public API

    /// Plans and applies the initial window.
    public func start() {
        suppressed.removeAll()
        observeQuality()
        reconcile()
    }

    /// Moves the cursor (clamped to the feed). Pass what you learned about
    /// the item being left so the skip model can update first.
    public func move(to index: Int, leaving observation: SkipPredictor.Observation? = nil) {
        let target = items.isEmpty ? 0 : min(max(0, index), items.count - 1)
        // Only a real move leaves a clip; a swipe past the end of the feed
        // teaches the skip model nothing.
        if target != cursor, let observation { predictor.learn(observation) }
        suppressed.removeAll()
        cursor = target
        observeQuality()
        reconcile()
    }

    /// Moves relative to the engine's own cursor, so two quick swipes can
    /// never both start from the same stale position.
    public func move(by delta: Int, leaving observation: SkipPredictor.Observation? = nil) {
        move(to: Saturating.addInt(cursor, delta), leaving: observation)
    }

    /// New device conditions: updates the quality ladder, then the window.
    ///
    /// The ladder reads the throughput estimate in `conditions`. Its up-switch
    /// dwell is measured in time, and the engine re-checks it on every
    /// `update`, swipe and completed download, so quality recovers while the
    /// feed is in use. An app that sits on one long clip with no downloads
    /// should call this with each new throughput estimate.
    public func update(conditions newConditions: DeviceConditions) {
        conditions = newConditions
        suppressed.removeAll()
        observeQuality()
        reconcile()
    }

    /// Replaces the feed (pagination, refresh). The cursor is re-clamped.
    public func setItems(_ newItems: [FeedItem]) {
        items = newItems
        cursor = items.isEmpty ? 0 : min(max(0, cursor), items.count - 1)
        suppressed.removeAll()
        reconcile()
    }

    /// Suspends until every port call the engine started has completed and
    /// been applied. Used by the tests; the demo polls `Snapshot.pending`.
    public func waitUntilIdle() async {
        while pending > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    /// Rows from `behind` positions before the cursor to `ahead` after it
    /// (each clamped to 0...64), plus budgets, statistics and diagnostics.
    public func snapshot(behind: Int = 2, ahead: Int = 6) -> Snapshot {
        let back = min(max(0, behind), 64)
        let forward = min(max(0, ahead), 64)
        var rows: [Row] = []
        if !items.isEmpty {
            let low = max(0, cursor - back)
            let high = min(items.count - 1, Saturating.addInt(cursor, forward))
            let slots = lastPlan.slots
            for index in low ... high {
                let item = items[index]
                let planned = slots.first(where: { $0.index == index })?.rendition
                    ?? item.rendition(cappedAt: ladder.capKbps)
                let held = heldRendition(of: item) ?? planned
                let cached = planned.map { committedBytes(for: CacheKey(item: item.id, rendition: $0.id)) } ?? 0
                let perSecond = planned?.bytesPerSecond ?? 0
                rows.append(Row(index: index, item: item.id, tier: lastPlan.tier(at: index),
                                decoder: decoderStatus(of: item.id),
                                rendition: held.map { "\($0.height)p" } ?? "—",
                                plannedRendition: planned.map { "\($0.height)p" } ?? "—",
                                cachedBytes: cached,
                                cachedSeconds: perSecond > 0 ? Double(cached) / Double(perSecond) : 0))
            }
        }
        var reserved: Int64 = 0
        for (key, flight) in inFlight {
            reserved = Saturating.add(reserved, max(0, Saturating.subtract(cache.bytes(for: key), flight.committedBefore)))
        }
        let skip = predictor.skipProbability
        let secondsInUse: Double
        if conditions.network == .offline {
            secondsInUse = 0
        } else {
            secondsInUse = skip >= configuration.skipThreshold ? lastShape.firstSegmentSeconds : lastShape.prefetchSeconds
        }
        return Snapshot(cursor: lastPlan.cursor, itemCount: items.count, conditions: conditions, shape: lastShape,
                        prefetchSecondsInUse: secondsInUse, skipThreshold: configuration.skipThreshold,
                        qualityLevel: ladder.level, qualityCapKbps: ladder.capKbps, skipProbability: skip,
                        decoderCapacity: pool.capacity, decodersInUse: pool.inUse,
                        cacheBytes: max(0, Saturating.subtract(cache.totalBytes, reserved)),
                        cacheReservedBytes: reserved, cacheBudgetBytes: cache.budgetBytes,
                        rows: rows, diagnostics: lastPlan.diagnostics, stats: stats, pending: pending)
    }

    /// Consistency of the engine's own books (pool, cache, held leases,
    /// in-flight fetches). Empty means consistent.
    public func invariantViolations() -> [String] {
        var problems = pool.invariantViolations + cache.invariantViolations
        for (key, entry) in held where pool.lease(for: key) != entry.lease {
            problems.append("held lease \(entry.lease) not current in pool")
        }
        for lease in releasing where !pool.isCurrent(lease) {
            problems.append("releasing lease \(lease) already freed")
        }
        if held.count + releasing.count != pool.inUse {
            problems.append("held \(held.count) + releasing \(releasing.count) != pool in use \(pool.inUse)")
        }
        if let playingLease, held[playingLease.key]?.lease != playingLease || held[playingLease.key]?.state != .ready {
            problems.append("playing lease \(playingLease) is not a held, ready decoder")
        }
        for (key, flight) in inFlight where cache.bytes(for: key) < flight.committedBefore {
            problems.append("in-flight \(key) lost its committed bytes")
        }
        // Once settled, the clip on screen must be the one the plan wants:
        // a hand-off may be in progress while work is pending, never after.
        // (A replacement whose prepare failed is suppressed until the next
        // event; the old rendition playing on meanwhile is intended.)
        if pending == 0, let playingLease {
            if let wanted = lastPlan.playing?.decoderKey {
                if wanted != playingLease.key, !suppressed.contains(wanted) {
                    problems.append("settled with \(playingLease.key) playing but the plan wants \(wanted)")
                }
            } else {
                problems.append("settled with \(playingLease.key) playing but the plan wants nothing")
            }
        }
        return problems
    }

    // MARK: - Reconcile

    @discardableResult
    private func observeQuality() -> Bool {
        switch ladder.observe(conditions, at: clock.now()) {
        case .up?:
            Saturating.increment(&stats.qualityUps)
            return true
        case .down?:
            Saturating.increment(&stats.qualityDowns)
            return true
        case nil:
            return false
        }
    }

    private func committedBytes(for key: CacheKey) -> Int64 {
        inFlight[key]?.committedBefore ?? cache.bytes(for: key)
    }

    private func committedBytes() -> [CacheKey: Int64] {
        var result: [CacheKey: Int64] = [:]
        for key in cache.keys {
            result[key] = committedBytes(for: key)
        }
        return result
    }

    /// The rendition a decoder for `item` actually holds: the playing lease
    /// first, then a ready one, then one still preparing.
    private func heldRendition(of item: FeedItem) -> Rendition? {
        let leases = held.filter { $0.key.item == item.id }.values
        let chosen = leases.first(where: { $0.lease == playingLease })
            ?? leases.filter { $0.state == .ready }.min(by: { $0.lease.key < $1.lease.key })
            ?? leases.min(by: { $0.lease.key < $1.lease.key })
        guard let key = chosen?.lease.key else { return nil }
        return item.renditions.first { $0.id == key.rendition }
    }

    private func decoderStatus(of item: ItemID) -> DecoderStatus {
        var best = DecoderStatus.idle
        func rank(_ status: DecoderStatus) -> Int {
            switch status {
            case .idle: 0
            case .releasing: 1
            case .preparing: 2
            case .ready: 3
            case .playing: 4
            }
        }
        for (key, entry) in held where key.item == item {
            let status: DecoderStatus = entry.lease == playingLease ? .playing : (entry.state == .ready ? .ready : .preparing)
            if rank(status) > rank(best) { best = status }
        }
        if best == .idle, releasing.contains(where: { $0.key.item == item }) { best = .releasing }
        return best
    }

    private func reconcile() {
        Saturating.increment(&stats.reconciles)
        let shape = policy.shape(for: conditions, decoderCapacity: pool.capacity)
        let input = PlannerInput(items: items, cursor: cursor, shape: shape, decoderCapacity: pool.capacity,
                                 qualityCapKbps: ladder.capKbps, network: conditions.network,
                                 skipProbability: predictor.skipProbability,
                                 skipThreshold: configuration.skipThreshold,
                                 committedBytes: committedBytes(),
                                 preparedDecoders: Set(held.filter { $0.value.state == .ready }.keys))
        let plan = planner.plan(input)
        lastPlan = plan
        lastShape = shape
        cache.setPinned(plan.pinnedKeys)
        // Playback first: a hand-off to an already-ready replacement must be
        // queued before the old decoder's release, which the decoder pass
        // below issues.
        reconcilePlayback(plan)
        reconcileDecoders(plan)
        unblockHandOff(plan)
        reconcilePrefetch(plan)
    }

    private func reconcilePlayback(_ plan: ReadinessPlan) {
        if let current = playingLease, plan.playing?.item != current.key.item {
            // The user left this clip (or it can no longer play): stop it
            // now, even if the next clip is not ready yet.
            playingLease = nil
            Saturating.increment(&stats.pausesSent)
            enqueueControl { [player] in
                await player.pause(current)
                await self.taskFinished()
            }
        }
        guard let slot = plan.playing, let entry = held[slot.decoderKey], entry.state == .ready,
              playingLease != entry.lease else { return }
        // Non-nil only for a rendition switch of the same clip (hand-off).
        let previous = playingLease
        if previous != nil { Saturating.increment(&stats.handOffs) }
        playingLease = entry.lease
        Saturating.increment(&stats.playbackStarts)
        let next = entry.lease
        enqueueControl { [player] in
            if let previous { await player.pause(previous) }
            await player.play(next)
            await self.taskFinished()
        }
    }

    /// Make-before-break: the clip on screen keeps its decoder, and keeps
    /// playing, until the replacement rendition for the same clip is ready.
    private func keepForHandOff(_ lease: DecoderLease, plan: ReadinessPlan) -> Bool {
        guard !faults.contains(.breakBeforeMake), lease == playingLease,
              let playing = plan.playing, playing.item == lease.key.item else { return false }
        return held[playing.decoderKey]?.state != .ready
    }

    private func reconcileDecoders(_ plan: ReadinessPlan) {
        let desired = Set(plan.decoderKeys)

        for key in held.keys.sorted() where !desired.contains(key) {
            guard let entry = held[key] else { continue }
            switch entry.state {
            case .ready:
                if keepForHandOff(entry.lease, plan: plan) { continue }
                held[key] = nil
                beginRelease(entry.lease)
            case .preparing:
                if faults.contains(.releaseWhilePreparing) {
                    held[key] = nil
                    pool.release(entry.lease)
                    spawn { [player] in
                        await player.release(entry.lease)
                        await self.taskFinished()
                    }
                } else {
                    held[key]?.releaseWhenPrepared = true
                }
            }
        }

        for slot in plan.slots {
            let key = slot.decoderKey
            if held[key] != nil {
                // Wanted again before its prepare finished: keep it.
                held[key]?.releaseWhenPrepared = false
                continue
            }
            if suppressed.contains(key) { continue }
            if let existing = pool.lease(for: key), releasing.contains(existing) {
                // Its previous decoder is still being torn down; the release
                // completion re-plans and acquires it then.
                Saturating.increment(&stats.decoderBusy)
                continue
            }
            // `slot.index` comes from the planner and indexes `items`;
            // checked anyway rather than trusted.
            guard items.indices.contains(slot.index), items[slot.index].id == slot.item else { continue }
            let item = items[slot.index]
            switch pool.acquire(key) {
            case .failure:
                Saturating.increment(&stats.decoderBusy)
            case .success(let lease):
                held[key] = Held(lease: lease, state: .preparing, releaseWhenPrepared: false)
                Saturating.increment(&stats.preparesStarted)
                stats.peakDecodersInUse = max(stats.peakDecodersInUse, pool.inUse)
                let rendition = slot.rendition
                spawn { [player] in
                    let ok: Bool
                    do {
                        try await player.prepare(item, rendition: rendition, lease: lease)
                        ok = true
                    } catch {
                        ok = false
                    }
                    await self.prepareFinished(lease, succeeded: ok)
                }
            }
        }
    }

    /// Make-before-break needs a free slot for the playing clip's new
    /// rendition while the old one keeps playing. When the pool is full and
    /// nothing is already on its way out, free one: pre-empt the
    /// lowest-priority *ready* prepared decoder (it is re-prepared once the
    /// hand-off completes). With a single-decoder budget there is nothing to
    /// pre-empt, so fall back to break-before-make. If other decoders are
    /// still preparing, wait: they become pre-emptable when they finish.
    private func unblockHandOff(_ plan: ReadinessPlan) {
        guard !faults.contains(.noHandOffPreemption),
              let current = playingLease, let target = plan.playing,
              target.item == current.key.item, target.decoderKey != current.key,
              held[target.decoderKey] == nil, pool.lease(for: target.decoderKey) == nil,
              !suppressed.contains(target.decoderKey),
              pool.inUse >= pool.capacity,
              releasing.isEmpty, !held.values.contains(where: { $0.releaseWhenPrepared }) else { return }
        let victim = plan.prepared.reversed()
            .compactMap { held[$0.decoderKey] }
            .first { $0.state == .ready && $0.lease != current }
        if let victim {
            held[victim.lease.key] = nil
            Saturating.increment(&stats.preemptions)
            beginRelease(victim.lease)
        } else if held.values.allSatisfy({ $0.lease == current }) {
            held[current.key] = nil
            Saturating.increment(&stats.breakBeforeMakeFallbacks)
            beginRelease(current)
        }
    }

    private func prepareFinished(_ lease: DecoderLease, succeeded: Bool) {
        defer { taskFinished() }
        guard let entry = held[lease.key], entry.lease == lease else {
            // Only reachable with the `.releaseWhilePreparing` fault: the
            // lease was already dropped while preparing.
            return
        }
        if !succeeded {
            Saturating.increment(&stats.preparesFailed)
            held[lease.key] = nil
            // The release below re-plans when it completes; suppression keeps
            // that re-plan from retrying this key straight away.
            if !faults.contains(.noFailureSuppression) { suppressed.insert(lease.key) }
            beginRelease(lease)
            return
        }
        if entry.releaseWhenPrepared {
            Saturating.increment(&stats.deferredReleases)
            held[lease.key] = nil
            beginRelease(lease)
            return
        }
        held[lease.key]?.state = .ready
        // May start playback, complete a hand-off and retire the old decoder.
        reconcile()
    }

    private func beginRelease(_ lease: DecoderLease) {
        releasing.insert(lease)
        // Releasing the playing decoder stops it; no separate pause.
        if playingLease == lease { playingLease = nil }
        enqueueControl { [player] in
            await player.release(lease)
            await self.releaseFinished(lease)
        }
    }

    private func releaseFinished(_ lease: DecoderLease) {
        releasing.remove(lease)
        if !faults.contains(.forgetPoolRelease) { pool.release(lease) }
        Saturating.increment(&stats.releasesCompleted)
        // A slot just became free; a planned item may have been waiting for it.
        reconcile()
        taskFinished()
    }

    private func reconcilePrefetch(_ plan: ReadinessPlan) {
        var wanted: [CacheKey: PrefetchRequest] = [:]
        for request in plan.prefetch { wanted[request.key] = request }
        var keep = Set(wanted.keys)
        if !faults.contains(.cancelFetchesOnLanding), conditions.network != .offline {
            // A clip that moved from "ahead" into a decoder tier (the user
            // landed on it) keeps its download: those bytes are exactly the
            // ones it needs next. Its key is pinned by the plan too.
            // Offline, every download is cancelled: none can complete.
            keep.formUnion(plan.slots.map { CacheKey(item: $0.item, rendition: $0.rendition.id) })
        }

        for key in inFlight.keys.sorted() where !keep.contains(key) {
            cancelFetch(key)
        }

        for request in plan.prefetch where inFlight[request.key] == nil {
            let committed = cache.bytes(for: request.key)
            guard request.targetBytes > committed else { continue }
            switch cache.reserve(request.key, totalBytes: request.targetBytes) {
            case .failure:
                Saturating.increment(&stats.cacheRefusals)
            case .success(let evicted):
                for victim in evicted {
                    Saturating.increment(&stats.evictions)
                    // Victims are unpinned and every in-flight key is pinned,
                    // so this should never fire; handled anyway rather than
                    // leaving a fetch writing into an evicted entry.
                    if inFlight[victim] != nil { cancelFetch(victim) }
                }
                let token = nextToken
                // One token per fetch; `&+` documents that wrapping (after
                // 2^64 fetches) rather than trapping is the fallback.
                nextToken &+= 1
                let key = request.key
                let target = request.targetBytes
                Saturating.increment(&stats.prefetchesStarted)
                let task = spawn { [transport] in
                    let ok: Bool
                    do {
                        try await transport.fetch(key, fromByte: committed, toByte: target)
                        ok = !Task.isCancelled
                    } catch {
                        ok = false
                    }
                    await self.fetchFinished(key, token: token, succeeded: ok)
                }
                inFlight[key] = InFlight(token: token, committedBefore: committed, task: task)
            }
        }
    }

    private func cancelFetch(_ key: CacheKey) {
        guard let flight = inFlight.removeValue(forKey: key) else { return }
        flight.task.cancel()
        let reserved = cache.bytes(for: key)
        stats.bytesCancelled = Saturating.add(stats.bytesCancelled,
                                              max(0, Saturating.subtract(reserved, flight.committedBefore)))
        cache.shrink(key, to: flight.committedBefore)
        Saturating.increment(&stats.prefetchesCancelled)
    }

    private func fetchFinished(_ key: CacheKey, token: UInt64, succeeded: Bool) {
        defer { taskFinished() }
        guard let flight = inFlight[key],
              flight.token == token || faults.contains(.acceptStaleFetchCompletions) else {
            // Cancelled (and possibly re-requested) since this fetch started.
            Saturating.increment(&stats.staleFetchCompletions)
            return
        }
        inFlight[key] = nil
        if succeeded {
            stats.bytesFetched = Saturating.add(stats.bytesFetched,
                                                max(0, Saturating.subtract(cache.bytes(for: key), flight.committedBefore)))
            cache.touch(key)
            // A completed download is a check-point for the ladder's dwell
            // timer. Re-plan if the cap moved, or if the plan already wants
            // more of this key than the download that just ended fetched
            // (its target grew while it was in flight), so the engine does
            // not go idle short of its own plan.
            let wantsMore = lastPlan.prefetch.contains { $0.key == key && $0.targetBytes > cache.bytes(for: key) }
            if observeQuality() || wantsMore { reconcile() }
        } else {
            Saturating.increment(&stats.prefetchesFailed)
            cache.shrink(key, to: flight.committedBefore)
        }
    }

    // MARK: - Task bookkeeping

    /// Runs `operation` concurrently. The operation must end by calling
    /// `taskFinished()` (directly or via a completion handler that does).
    @discardableResult
    private func spawn(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Saturating.increment(&pending)
        return Task { await operation() }
    }

    /// Runs `operation` after every previously enqueued control command has
    /// finished (FIFO). Same `taskFinished()` contract as `spawn`.
    private func enqueueControl(_ operation: @escaping @Sendable () async -> Void) {
        if faults.contains(.unorderedPortCommands) {
            spawn(operation)
            return
        }
        Saturating.increment(&pending)
        let previous = controlTail
        controlTail = Task {
            await previous?.value
            await operation()
        }
    }

    private func taskFinished() {
        pending = max(0, pending - 1)
        guard pending == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
