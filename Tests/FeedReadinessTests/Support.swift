import Foundation
@testable import FeedReadiness

/// Deterministic PRNG so fuzz tests are reproducible on every platform.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A clock that only moves when a test says so.
final class ManualClock: FeedClock, @unchecked Sendable {
    // NSLock guards `seconds`; the engine reads it from its own actor.
    private let lock = NSLock()
    private var seconds: Double = 0

    func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    func advance(by delta: Double) {
        lock.lock()
        seconds += delta
        lock.unlock()
    }
}

/// A transport whose fetches wait at a gate, in call order, until the test
/// releases them. Ignores cancellation (like a download already on the wire).
actor GatedTransport: PrefetchTransport {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func fetch(_ key: CacheKey, fromByte: Int64, toByte: Int64) async throws {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    var waiting: Int { waiters.count }

    /// Lets the `count` oldest waiting fetches complete.
    func release(first count: Int) {
        let n = min(max(0, count), waiters.count)
        let released = waiters.prefix(n)
        waiters.removeFirst(n)
        for continuation in released { continuation.resume() }
    }

    /// Releases everything waiting and lets future fetches pass straight through.
    func openAll() {
        open = true
        release(first: waiters.count)
    }
}

enum Fixtures {
    static let ladder = [
        Rendition(id: "360", height: 360, bitrateKbps: 600),
        Rendition(id: "540", height: 540, bitrateKbps: 1_200),
        Rendition(id: "720", height: 720, bitrateKbps: 2_500),
        Rendition(id: "1080", height: 1_080, bitrateKbps: 5_000),
    ]

    static func feed(_ count: Int, duration: Double = 20) -> [FeedItem] {
        (0 ..< max(0, count)).map { FeedItem(id: ItemID("v\($0)"), renditions: ladder, durationSeconds: duration) }
    }

    static func input(items: [FeedItem], cursor: Int = 0, capacity: Int = 4,
                      conditions: DeviceConditions = .ideal, cap: Int = 5_000,
                      skip: Double = 0.5, committed: [CacheKey: Int64] = [:]) -> PlannerInput {
        PlannerInput(items: items, cursor: cursor,
                     shape: DefaultWindowPolicy().shape(for: conditions, decoderCapacity: capacity),
                     decoderCapacity: capacity, qualityCapKbps: cap, network: conditions.network,
                     skipProbability: skip, committedBytes: committed)
    }
}
