/// Monotonic seconds for the engine's time-based decisions (the quality
/// ladder's up-switch dwell). Injected so tests can control time exactly.
public protocol FeedClock: Sendable {
    /// Seconds since an arbitrary fixed origin; never decreases.
    func now() -> Double
}

/// `ContinuousClock`-backed clock: seconds since this value was created.
public struct SystemFeedClock: FeedClock {
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock.now
    }

    public func now() -> Double {
        let parts = origin.duration(to: ContinuousClock.now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
