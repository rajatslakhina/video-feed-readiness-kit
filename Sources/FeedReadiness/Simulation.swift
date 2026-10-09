/// In-memory ports with configurable latency, used by the demo app and the
/// tests. They also *check the port contract*, so an engine bug shows up as
/// a number rather than a flaky crash:
/// - decoders live at once (`maxLiveDecoders`) — the hardware budget;
/// - a `release` that arrives while that lease is still preparing, and the
///   decoder that consequently leaks;
/// - the set of leases currently playing (`playing`) and its peak — more
///   than one means two clips play over each other;
/// - `play`/`pause` for a lease that is not live (already released, or
///   never prepared), or `play` for a lease whose prepare failed — an
///   ordering or contract bug between control commands.
///
/// Tests can also hold every prepare at a gate (`holdPrepares()` /
/// `openPrepares()`) to freeze the engine mid-switch deterministically,
/// instead of racing a sleep against a latency.
public actor SimulatedPlayer: PlayerPort {
    public struct Report: Sendable, Equatable {
        public var prepares = 0
        public var failures = 0
        public var releases = 0
        public var liveDecoders = 0
        public var maxLiveDecoders = 0
        /// `release` arrived while that lease's `prepare` was still running.
        public var releasesDuringPrepare = 0
        /// Decoders that are still allocated although their lease was released.
        public var leakedDecoders = 0
        /// Leases playing right now. Exactly one (or none) is correct.
        public var playing: Set<DecoderLease> = []
        public var maxSimultaneouslyPlaying = 0
        /// `play` or `pause` for a lease that is not live, or `play` for a
        /// lease whose prepare failed.
        public var commandsForDeadLeases = 0
        public init() {}
    }

    public let prepareLatency: Duration
    public let playLatency: Duration
    public let pauseLatency: Duration
    public let releaseLatency: Duration
    /// Every `failEvery`-th prepare throws. 0 disables failures.
    public let failEvery: Int
    private var preparing: Set<DecoderLease> = []
    private var live: Set<DecoderLease> = []
    private var releasedEarly: Set<DecoderLease> = []
    private var failed: Set<DecoderLease> = []
    private var gateClosed = false
    private var gated: [CheckedContinuation<Void, Never>] = []
    private var report = Report()

    public struct InjectedFailure: Error {}

    public init(prepareLatency: Duration = .zero, playLatency: Duration = .zero,
                pauseLatency: Duration = .zero, releaseLatency: Duration = .zero, failEvery: Int = 0) {
        self.prepareLatency = prepareLatency
        self.playLatency = playLatency
        self.pauseLatency = pauseLatency
        self.releaseLatency = releaseLatency
        self.failEvery = max(0, failEvery)
    }

    public func prepare(_ item: FeedItem, rendition: Rendition, lease: DecoderLease) async throws {
        Saturating.increment(&report.prepares)
        // Captured before the first suspension: with concurrent prepares the
        // shared counter moves on while this one sleeps.
        let ordinal = report.prepares
        preparing.insert(lease)
        // The decoder is allocated as soon as preparation starts.
        live.insert(lease)
        report.liveDecoders = live.count
        report.maxLiveDecoders = max(report.maxLiveDecoders, live.count)
        await delay(prepareLatency)
        if gateClosed {
            await withCheckedContinuation { gated.append($0) }
        }
        preparing.remove(lease)
        if releasedEarly.contains(lease) {
            // The engine released this lease before we finished creating it.
            // A real AVPlayer created now has no owner: it leaks.
            Saturating.increment(&report.leakedDecoders)
        }
        if failEvery > 0, ordinal % failEvery == 0 {
            Saturating.increment(&report.failures)
            failed.insert(lease)
            throw InjectedFailure()
        }
    }

    public func play(_ lease: DecoderLease) async {
        await delay(playLatency)
        guard live.contains(lease), !preparing.contains(lease), !failed.contains(lease) else {
            Saturating.increment(&report.commandsForDeadLeases)
            return
        }
        report.playing.insert(lease)
        report.maxSimultaneouslyPlaying = max(report.maxSimultaneouslyPlaying, report.playing.count)
    }

    public func pause(_ lease: DecoderLease) async {
        await delay(pauseLatency)
        guard live.contains(lease) else {
            Saturating.increment(&report.commandsForDeadLeases)
            return
        }
        report.playing.remove(lease)
    }

    public func release(_ lease: DecoderLease) async {
        Saturating.increment(&report.releases)
        if preparing.contains(lease) {
            // Contract violation: the port cannot tear down what it has not
            // finished creating, so the decoder stays allocated.
            Saturating.increment(&report.releasesDuringPrepare)
            releasedEarly.insert(lease)
            return
        }
        await delay(releaseLatency)
        live.remove(lease)
        report.playing.remove(lease)
        report.liveDecoders = live.count
    }

    public func currentReport() -> Report { report }

    /// From now on, every prepare waits at a gate after its latency.
    public func holdPrepares() {
        gateClosed = true
    }

    /// Opens the gate: prepares waiting at it continue, new ones pass.
    public func openPrepares() {
        gateClosed = false
        let waiting = gated
        gated = []
        for continuation in waiting { continuation.resume() }
    }

    /// Prepares currently waiting at the gate.
    public var preparesAtGate: Int { gated.count }

    private func delay(_ duration: Duration) async {
        if duration > .zero {
            try? await Task.sleep(for: duration)
        }
    }
}

/// Simulated network: delivers bytes at `bytesPerSecond`, honours
/// cancellation, and fails every `failEvery`-th fetch.
public actor SimulatedTransport: PrefetchTransport {
    public let bytesPerSecond: Int64
    public let failEvery: Int
    private var fetches = 0
    public private(set) var completedBytes: Int64 = 0

    public struct InjectedFailure: Error {}

    public init(bytesPerSecond: Int64 = 0, failEvery: Int = 0) {
        self.bytesPerSecond = max(0, bytesPerSecond)
        self.failEvery = max(0, failEvery)
    }

    public func fetch(_ key: CacheKey, fromByte: Int64, toByte: Int64) async throws {
        Saturating.increment(&fetches)
        // Captured before suspending; see `SimulatedPlayer.prepare`.
        let ordinal = fetches
        let count = max(0, Saturating.subtract(toByte, fromByte))
        if bytesPerSecond > 0 {
            // Capped at 2 s so a huge request cannot stall the demo.
            let seconds = min(2.0, Double(count) / Double(bytesPerSecond))
            try await Task.sleep(for: .milliseconds(Saturating.nonNegativeInt64(seconds * 1_000)))
        }
        try Task.checkCancellation()
        if failEvery > 0, ordinal % failEvery == 0 { throw InjectedFailure() }
        completedBytes = Saturating.add(completedBytes, count)
    }
}
