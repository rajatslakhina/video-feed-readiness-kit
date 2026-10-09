/// Readiness tier of one feed position.
public enum ReadinessTier: Int, Sendable, Comparable, CaseIterable {
    case cold = 0, prefetched, prepared, playing
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// An item placed in a decoder tier.
public struct PlannedSlot: Hashable, Sendable {
    public let index: Int
    public let item: ItemID
    public let rendition: Rendition
    public var decoderKey: DecoderKey { DecoderKey(item: item, rendition: rendition.id) }
}

/// Bring `key` up to `targetBytes` cached bytes.
public struct PrefetchRequest: Hashable, Sendable {
    public let index: Int
    public let key: CacheKey
    public let targetBytes: Int64
    /// True when the skip model shortened this request to the first segment.
    public let shortenedForLikelySkip: Bool
}

/// One position inside the prefetch window and the cache key it would use.
/// Fully cached positions are listed too (they need no request, but their
/// bytes must stay pinned).
public struct WindowEntry: Hashable, Sendable {
    public let index: Int
    public let key: CacheKey
}

public enum PlanDiagnostic: Hashable, Sendable {
    case emptyFeed
    case cursorClamped(requested: Int, used: Int)
    case unplayable(ItemID)
    case notCachedWhileOffline(ItemID)
    case noDecoderForPlayback
}

/// Everything the planner needs, as plain values.
public struct PlannerInput: Sendable {
    public var items: [FeedItem]
    public var cursor: Int
    public var shape: WindowShape
    public var decoderCapacity: Int
    public var qualityCapKbps: Int
    public var network: NetworkClass
    /// Probability the user skips the next item (from `SkipPredictor`).
    public var skipProbability: Double
    /// At or above this probability, prefetch is cut to the first segment.
    public var skipThreshold: Double
    /// Bytes already *delivered* per key (excludes in-flight reservations).
    public var committedBytes: [CacheKey: Int64]
    /// Decoders that are already prepared (their player has buffered the
    /// start of the clip). Offline, these can keep playing or start even if
    /// the prefetch cache holds nothing for them.
    public var preparedDecoders: Set<DecoderKey>

    public init(items: [FeedItem], cursor: Int, shape: WindowShape, decoderCapacity: Int,
                qualityCapKbps: Int, network: NetworkClass, skipProbability: Double = 0.5,
                skipThreshold: Double = 0.7, committedBytes: [CacheKey: Int64] = [:],
                preparedDecoders: Set<DecoderKey> = []) {
        self.items = items
        self.cursor = cursor
        self.shape = shape
        self.decoderCapacity = decoderCapacity
        self.qualityCapKbps = qualityCapKbps
        self.network = network
        self.skipProbability = skipProbability.sanitized(in: 0 ... 1, fallback: 0.5)
        self.skipThreshold = skipThreshold.sanitized(in: 0 ... 1, fallback: 0.7)
        self.committedBytes = committedBytes
        self.preparedDecoders = preparedDecoders
    }
}

/// The desired state around the cursor. Pure data; the engine diffs it
/// against what is actually held and applies the difference.
public struct ReadinessPlan: Equatable, Sendable {
    public var cursor: Int?
    public var playing: PlannedSlot?
    /// Decoder tier, highest priority first.
    public var prepared: [PlannedSlot]
    public var prefetch: [PrefetchRequest]
    /// Every position inside the prefetch window, including items whose
    /// bytes are already cached (and so need no request). Drives `tier(at:)`
    /// and pinning.
    public var prefetchWindow: [WindowEntry]
    public var diagnostics: [PlanDiagnostic]

    public init(cursor: Int?, playing: PlannedSlot?, prepared: [PlannedSlot], prefetch: [PrefetchRequest],
                prefetchWindow: [WindowEntry] = [], diagnostics: [PlanDiagnostic]) {
        self.cursor = cursor
        self.playing = playing
        self.prepared = prepared
        self.prefetch = prefetch
        self.prefetchWindow = prefetchWindow
        self.diagnostics = diagnostics
    }

    public static let empty = ReadinessPlan(cursor: nil, playing: nil, prepared: [], prefetch: [], diagnostics: [])

    /// Cache keys that must not be evicted while this plan holds: the
    /// exact rendition of every decoder slot and every window position.
    /// Other renditions of the same items are deliberately *not* pinned.
    public var pinnedKeys: Set<CacheKey> {
        var pinned = Set(slots.map { CacheKey(item: $0.item, rendition: $0.rendition.id) })
        pinned.formUnion(prefetchWindow.map(\.key))
        pinned.formUnion(prefetch.map(\.key))
        return pinned
    }

    /// Playing first, then prepared in priority order.
    public var slots: [PlannedSlot] {
        (playing.map { [$0] } ?? []) + prepared
    }

    /// Decoder keys in priority order: playing first.
    public var decoderKeys: [DecoderKey] {
        slots.map(\.decoderKey)
    }

    public func tier(at index: Int) -> ReadinessTier {
        if playing?.index == index { return .playing }
        if prepared.contains(where: { $0.index == index }) { return .prepared }
        if prefetchWindow.contains(where: { $0.index == index }) || prefetch.contains(where: { $0.index == index }) {
            return .prefetched
        }
        return .cold
    }
}

/// Pure, deterministic planning: same input, same plan.
public struct ReadinessPlanner: Sendable {
    public init() {}

    /// Renditions of `item` (ascending bitrate) that can start with no
    /// network: a decoder for it is already prepared (its player buffered
    /// the start), or its first segment is in the cache.
    public static func startableOffline(_ item: FeedItem, input: PlannerInput) -> [Rendition] {
        item.renditions.filter { rendition in
            if input.preparedDecoders.contains(DecoderKey(item: item.id, rendition: rendition.id)) { return true }
            let firstSegment = rendition.bytes(forSeconds: input.shape.firstSegmentSeconds)
            return (input.committedBytes[CacheKey(item: item.id, rendition: rendition.id)] ?? 0) >= max(1, firstSegment)
        }
    }

    public func plan(_ input: PlannerInput) -> ReadinessPlan {
        let items = input.items
        guard !items.isEmpty else {
            return ReadinessPlan(cursor: nil, playing: nil, prepared: [], prefetch: [], diagnostics: [.emptyFeed])
        }
        var diagnostics: [PlanDiagnostic] = []
        let cursor = min(max(0, input.cursor), items.count - 1)
        if cursor != input.cursor {
            diagnostics.append(.cursorClamped(requested: input.cursor, used: cursor))
        }
        let offline = input.network == .offline
        let cap = input.qualityCapKbps

        // A rendition for a decoder tier. Online: the best one under the cap.
        // Offline: only a rendition that can start without the network
        // qualifies (see `startableOffline`); the best such one under the cap,
        // or, if none is under it, the lowest one above it. Offline the cap is
        // a preference: a clip that can play is never refused because of it.
        func decodableRendition(for item: FeedItem) -> Rendition? {
            guard offline else { return item.rendition(cappedAt: cap) }
            let startable = Self.startableOffline(item, input: input)
            return startable.last(where: { $0.bitrateKbps <= cap }) ?? startable.first
        }

        // Playing. Index is `cursor`, which is in range by the clamp above.
        var playing: PlannedSlot?
        let current = items[cursor]
        let decoders = max(0, input.decoderCapacity)
        if !current.isPlayable {
            diagnostics.append(.unplayable(current.id))
        } else if decoders == 0 {
            diagnostics.append(.noDecoderForPlayback)
        } else if let rendition = decodableRendition(for: current) {
            playing = PlannedSlot(index: cursor, item: current.id, rendition: rendition)
        } else {
            diagnostics.append(.notCachedWhileOffline(current.id))
        }

        // Prepared: nearest first, ahead before behind at equal distance.
        // Never more than `decoderCapacity - 1` (one is reserved for playing
        // even when the playing item failed, so a recovery never has to evict).
        let spare = Saturating.spareDecoders(decoders)
        var prepared: [PlannedSlot] = []
        var used = Set<ItemID>(playing.map { [$0.item] } ?? [])
        // Bounded by the feed length so a custom policy returning a huge
        // window cannot turn this into an unbounded loop.
        let reach = min(max(input.shape.preparedAhead, input.shape.preparedBehind), items.count)
        if reach > 0, spare > 0 {
            for distance in 1 ... reach where prepared.count < spare {
                var offsets: [Int] = []
                if distance <= input.shape.preparedAhead { offsets.append(distance) }
                if distance <= input.shape.preparedBehind { offsets.append(-distance) }
                for offset in offsets where prepared.count < spare {
                    guard let index = Saturating.index(cursor, offset: offset, count: items.count) else { continue }
                    let item = items[index]
                    guard item.isPlayable else { diagnostics.append(.unplayable(item.id)); continue }
                    guard !used.contains(item.id) else { continue }
                    guard let rendition = decodableRendition(for: item) else {
                        diagnostics.append(.notCachedWhileOffline(item.id))
                        continue
                    }
                    used.insert(item.id)
                    prepared.append(PlannedSlot(index: index, item: item.id, rendition: rendition))
                }
            }
        }

        // Prefetch: items ahead only; nothing offline.
        var prefetch: [PrefetchRequest] = []
        var prefetchWindow: [WindowEntry] = []
        let shorten = input.skipProbability >= input.skipThreshold
        let seconds = shorten ? input.shape.firstSegmentSeconds : input.shape.prefetchSeconds
        if !offline, input.shape.prefetchAhead > 0, seconds > 0 {
            var seen = Set<ItemID>()
            for offset in 1 ... input.shape.prefetchAhead {
                guard let index = Saturating.index(cursor, offset: offset, count: items.count) else { break }
                let item = items[index]
                guard item.isPlayable, seen.insert(item.id).inserted,
                      let rendition = item.rendition(cappedAt: cap) else { continue }
                let key = CacheKey(item: item.id, rendition: rendition.id)
                prefetchWindow.append(WindowEntry(index: index, key: key))
                let target = min(rendition.bytes(forSeconds: seconds), item.fullBytes(at: rendition))
                let have = input.committedBytes[key] ?? 0
                guard target > have else { continue }
                prefetch.append(PrefetchRequest(index: index, key: key, targetBytes: target,
                                                shortenedForLikelySkip: shorten))
            }
        }

        return ReadinessPlan(cursor: cursor, playing: playing, prepared: prepared,
                             prefetch: prefetch, prefetchWindow: prefetchWindow, diagnostics: diagnostics)
    }
}

/// Structural checks any plan must pass, independent of how it was made.
/// Used by the tests (including against hand-broken plans, to prove the
/// checks are not vacuous) and available to apps as a debug assertion.
public enum ReadinessInvariants {
    public static func violations(of plan: ReadinessPlan, for input: PlannerInput) -> [String] {
        var problems: [String] = []
        let count = input.items.count
        guard count > 0 else {
            if plan.playing != nil || !plan.prepared.isEmpty || !plan.prefetch.isEmpty {
                problems.append("non-empty plan for empty feed")
            }
            return problems
        }
        let cursor = min(max(0, input.cursor), count - 1)
        if plan.cursor != cursor { problems.append("cursor \(String(describing: plan.cursor)) != clamped \(cursor)") }
        if let playing = plan.playing, playing.index != cursor {
            problems.append("playing index \(playing.index) != cursor \(cursor)")
        }
        let decoders = plan.prepared.count + (plan.playing == nil ? 0 : 1)
        if decoders > max(0, input.decoderCapacity) {
            problems.append("\(decoders) decoders planned, capacity \(input.decoderCapacity)")
        }
        let spare = Saturating.spareDecoders(input.decoderCapacity)
        if plan.prepared.count > spare {
            problems.append("prepared \(plan.prepared.count) exceeds spare decoders \(spare)")
        }
        let slots = plan.slots
        if Set(slots.map(\.item)).count != slots.count { problems.append("an item holds two decoders") }
        for slot in slots where !(0 ..< count).contains(slot.index) || input.items[slot.index].id != slot.item {
            problems.append("slot \(slot.item) at invalid index \(slot.index)")
        }
        // Distances use overflow-checked subtraction: a hand-built plan may
        // carry any Int as an index, and an overflowing distance is simply
        // "outside every window".
        for slot in plan.prepared {
            let allowed: Bool
            if let distance = Saturating.distance(from: cursor, to: slot.index) {
                allowed = distance > 0 ? distance <= input.shape.preparedAhead
                                       : (distance < 0 && distance >= -input.shape.preparedBehind)
            } else {
                allowed = false
            }
            if !allowed { problems.append("prepared \(slot.item) outside window (index \(slot.index))") }
        }
        if input.network == .offline, !plan.prefetch.isEmpty || !plan.prefetchWindow.isEmpty {
            problems.append("prefetch planned while offline")
        }
        func insidePrefetchWindow(_ index: Int) -> Bool {
            guard let distance = Saturating.distance(from: cursor, to: index) else { return false }
            return distance >= 1 && distance <= input.shape.prefetchAhead
        }
        for entry in plan.prefetchWindow {
            if !insidePrefetchWindow(entry.index) {
                problems.append("prefetch window index \(entry.index) outside window")
            } else if (0 ..< count).contains(entry.index), input.items[entry.index].id != entry.key.item {
                problems.append("prefetch window key/index mismatch for \(entry.key)")
            }
        }
        if !Set(plan.prefetch.map { WindowEntry(index: $0.index, key: $0.key) }).isSubset(of: Set(plan.prefetchWindow)) {
            problems.append("prefetch request outside the reported prefetch window")
        }
        for request in plan.prefetch {
            if !insidePrefetchWindow(request.index) {
                problems.append("prefetch \(request.key) outside window (index \(request.index))")
            }
            guard (0 ..< count).contains(request.index) else { continue }
            let item = input.items[request.index]
            if item.id != request.key.item { problems.append("prefetch key/index mismatch for \(request.key)") }
            if let rendition = item.renditions.first(where: { $0.id == request.key.rendition }),
               request.targetBytes > item.fullBytes(at: rendition) {
                problems.append("prefetch \(request.key) larger than the item")
            }
            if request.targetBytes <= (input.committedBytes[request.key] ?? 0) {
                problems.append("prefetch \(request.key) asks for bytes already cached")
            }
        }
        for slot in slots where slot.rendition.bitrateKbps > input.qualityCapKbps {
            // Above the cap is allowed only to avoid refusing a clip that can
            // play: online, when it is the item's lowest rendition; offline,
            // when it is the lowest startable one and none under the cap is.
            guard let item = input.items.first(where: { $0.id == slot.item }) else { continue }
            let allowed: Bool
            if input.network == .offline {
                let startable = ReadinessPlanner.startableOffline(item, input: input)
                allowed = !startable.contains { $0.bitrateKbps <= input.qualityCapKbps } && startable.first == slot.rendition
            } else {
                allowed = item.renditions.first == slot.rendition
            }
            if !allowed {
                problems.append("\(slot.item) at \(slot.rendition.bitrateKbps) kbps above cap \(input.qualityCapKbps)")
            }
        }
        if input.network == .offline {
            for slot in slots {
                guard let item = input.items.first(where: { $0.id == slot.item }) else { continue }
                if !ReadinessPlanner.startableOffline(item, input: input).contains(slot.rendition) {
                    problems.append("\(slot.item) planned offline at \(slot.rendition.id), which cannot start offline")
                }
            }
        }
        return problems
    }
}
