/// How far around the cursor each readiness tier reaches.
///
/// - `prepared*`: items that hold a hardware decoder and have their first
///   segment buffered, so a swipe starts playback with no spinner.
/// - `prefetchAhead`: items whose leading bytes are on disk but hold no
///   decoder (cheap in memory, costs bandwidth).
///
/// Fields are immutable and validated on init (non-negative counts, finite
/// seconds, `firstSegmentSeconds <= prefetchSeconds`), so an invalid shape
/// cannot be constructed and every consumer can rely on those bounds.
public struct WindowShape: Hashable, Sendable, CustomStringConvertible {
    public let preparedAhead: Int
    public let preparedBehind: Int
    public let prefetchAhead: Int
    /// Seconds of media prefetched per item when the user is likely to watch.
    public let prefetchSeconds: Double
    /// Seconds prefetched when the user is likely to skip: just enough to
    /// start instantly. Always `<= prefetchSeconds`.
    public let firstSegmentSeconds: Double

    public init(preparedAhead: Int, preparedBehind: Int, prefetchAhead: Int,
                prefetchSeconds: Double, firstSegmentSeconds: Double) {
        self.preparedAhead = max(0, preparedAhead)
        self.preparedBehind = max(0, preparedBehind)
        self.prefetchAhead = max(0, prefetchAhead)
        let seconds = prefetchSeconds.sanitized(in: 0 ... 600, fallback: 0)
        self.prefetchSeconds = seconds
        self.firstSegmentSeconds = firstSegmentSeconds.sanitized(in: 0 ... seconds, fallback: 0)
    }

    public static let closed = WindowShape(preparedAhead: 0, preparedBehind: 0, prefetchAhead: 0,
                                           prefetchSeconds: 0, firstSegmentSeconds: 0)

    /// True when no field of `self` exceeds the same field of `other`.
    public func fits(within other: WindowShape) -> Bool {
        preparedAhead <= other.preparedAhead
            && preparedBehind <= other.preparedBehind
            && prefetchAhead <= other.prefetchAhead
            && prefetchSeconds <= other.prefetchSeconds
            && firstSegmentSeconds <= other.firstSegmentSeconds
    }

    public var description: String {
        "prepared +\(preparedAhead)/-\(preparedBehind), prefetch +\(prefetchAhead) × \(prefetchSeconds)s"
    }
}

/// Maps device conditions to a window. Implementations must be **monotone**:
/// worse conditions never produce a larger window. `PolicyAudit` checks that
/// property exhaustively, so a policy change that violates it fails CI.
public protocol WindowPolicy: Sendable {
    func shape(for conditions: DeviceConditions, decoderCapacity: Int) -> WindowShape
}

/// The shipped policy. Every rule is a cap that only ever *lowers* a value,
/// and every rule for a condition also applies to all worse values of that
/// condition (offline inherits everything constrained does, and so on).
/// That cumulative structure is what makes the policy monotone by
/// construction; the audit then proves it for every combination.
public struct DefaultWindowPolicy: WindowPolicy {
    public let baseline: WindowShape
    /// Hard ceiling on any count, whatever the baseline says.
    public let maxWindow: Int

    public init(baseline: WindowShape = WindowShape(preparedAhead: 2, preparedBehind: 1, prefetchAhead: 5,
                                                    prefetchSeconds: 6, firstSegmentSeconds: 1.5),
                maxWindow: Int = 16) {
        self.baseline = baseline
        self.maxWindow = max(0, maxWindow)
    }

    public func shape(for c: DeviceConditions, decoderCapacity: Int) -> WindowShape {
        var ahead = min(baseline.preparedAhead, maxWindow)
        var behind = min(baseline.preparedBehind, maxWindow)
        var prefetch = min(baseline.prefetchAhead, maxWindow)
        var seconds = baseline.prefetchSeconds
        let first = baseline.firstSegmentSeconds

        // Network: cellular trims bandwidth spend; constrained (Low Data Mode,
        // poor link) keeps only one of everything; offline fetches nothing.
        if c.network <= .cellular {
            prefetch = min(prefetch, 3)
            seconds = min(seconds, 3)
        }
        if c.network <= .constrained {
            ahead = min(ahead, 1)
            behind = 0
            prefetch = min(prefetch, 1)
            seconds = min(seconds, first)
        }
        if c.network == .offline {
            prefetch = 0
        }

        // Low Power Mode: halve the decoder window (keeping at least one item
        // ahead if there was one) and the prefetch depth; drop "behind".
        if c.lowPowerMode {
            ahead = ahead > 0 ? max(1, ahead / 2) : 0
            behind = 0
            prefetch /= 2
        }

        // Thermal: decoders are the heat source, so they go first.
        if c.thermal >= .serious {
            ahead = min(ahead, 1)
            behind = 0
        }
        if c.thermal >= .critical {
            ahead = 0
            prefetch = min(prefetch, 1)
        }

        // Memory: a prepared player holds decoded frames; shed them.
        if c.memory >= .warning {
            ahead = min(ahead, 1)
            behind = 0
        }
        if c.memory >= .critical {
            ahead = 0
        }

        // Decoder budget: one decoder always belongs to the playing item.
        // `ahead` and `behind` are non-negative here (the baseline's counts
        // are validated by `WindowShape`), and `ahead <= spare` after the
        // first line, so `spare - ahead` cannot underflow.
        let spare = Saturating.spareDecoders(decoderCapacity)
        ahead = min(ahead, spare)
        behind = min(behind, spare - ahead)

        return WindowShape(preparedAhead: ahead, preparedBehind: behind, prefetchAhead: prefetch,
                           prefetchSeconds: seconds, firstSegmentSeconds: min(first, seconds))
    }
}

/// Exhaustive checks over every combination of discrete conditions.
public enum PolicyAudit {
    /// Every combination of network x thermal x memory x low-power (96 values).
    public static var allConditions: [DeviceConditions] {
        var result: [DeviceConditions] = []
        for network in NetworkClass.allCases {
            for thermal in ThermalLevel.allCases {
                for memory in MemoryPressure.allCases {
                    for lowPower in [false, true] {
                        result.append(DeviceConditions(network: network, lowPowerMode: lowPower,
                                                       thermal: thermal, memory: memory))
                    }
                }
            }
        }
        return result
    }

    public struct Violation: Hashable, Sendable, CustomStringConvertible {
        public let better: DeviceConditions
        public let worse: DeviceConditions
        public let betterShape: WindowShape
        public let worseShape: WindowShape
        public var description: String {
            "worse conditions \(worse) produced \(worseShape), larger than \(betterShape) for \(better)"
        }
    }

    /// Pairs where strictly-no-better conditions produced a window that does
    /// not fit inside the better one's. An empty result means monotone.
    public static func monotonicityViolations(of policy: some WindowPolicy,
                                              decoderCapacity: Int) -> [Violation] {
        let all = allConditions
        let shapes = all.map { policy.shape(for: $0, decoderCapacity: decoderCapacity) }
        var violations: [Violation] = []
        for (i, better) in all.enumerated() {
            for (j, worse) in all.enumerated() where i != j && worse.isNoBetter(than: better) {
                if !shapes[j].fits(within: shapes[i]) {
                    violations.append(Violation(better: better, worse: worse,
                                                betterShape: shapes[i], worseShape: shapes[j]))
                }
            }
        }
        return violations
    }

    /// Shapes whose prepared tiers would need more decoders than exist.
    public static func capacityViolations(of policy: some WindowPolicy,
                                          decoderCapacity: Int) -> [DeviceConditions] {
        let spare = Saturating.spareDecoders(decoderCapacity)
        return allConditions.filter {
            let s = policy.shape(for: $0, decoderCapacity: decoderCapacity)
            // Saturating: a custom policy may return `.max` for both counts.
            return Saturating.addInt(s.preparedAhead, s.preparedBehind) > spare
        }
    }
}
