/// A bitrate cap with asymmetric hysteresis.
///
/// Down-switches are immediate: a stall costs more than a blurry frame.
/// Up-switches need (a) throughput above the next level by an extra
/// `upgradeHeadroom` margin and (b) that condition to hold continuously for
/// `upgradeDwellSeconds` of time, and then move one level at a time.
/// Without both, throughput that oscillates around a level boundary flips
/// the rendition on every sample, which re-prepares decoders and throws away
/// cached bytes of the old rendition each time. `LadderAudit` measures that.
///
/// The dwell is measured in **time, not in observations**. Observations are
/// only check-points: `FeedEngine` observes on every condition update, swipe
/// and completed download, and none of those can satisfy the dwell by being
/// repeated, because a repeat does not move the clock. (An earlier version
/// counted observations; re-counting the same sample on every swipe then met
/// the dwell and flapped the quality. The engine-level oscillation test
/// guards against that regression.)
public struct QualityLadder: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// Bitrate caps, normalised to strictly ascending positive values.
        public let levelsKbps: [Int]
        /// Throughput must be `level * safetyFactor` to sustain a level.
        public let safetyFactor: Double
        /// Extra multiplier required before moving *up*.
        public let upgradeHeadroom: Double
        /// Seconds the up-switch condition must hold, uninterrupted, before
        /// one step up. 0 means "on the first qualifying observation".
        public let upgradeDwellSeconds: Double
        /// Highest level allowed in Low Power Mode.
        public let lowPowerMaxLevel: Int
        /// Highest level allowed at `.serious` thermal state (`.critical` pins level 0).
        public let seriousThermalMaxLevel: Int

        public init(levelsKbps: [Int] = [600, 1_200, 2_500, 5_000],
                    safetyFactor: Double = 1.5,
                    upgradeHeadroom: Double = 1.25,
                    upgradeDwellSeconds: Double = 4,
                    lowPowerMaxLevel: Int = 1,
                    seriousThermalMaxLevel: Int = 1) {
            let cleaned = Array(Set(levelsKbps.filter { $0 > 0 })).sorted()
            // An empty ladder would leave no valid level index; fall back to a
            // single "no cap" level so every index computation stays in range.
            self.levelsKbps = cleaned.isEmpty ? [Int.max] : cleaned
            self.safetyFactor = safetyFactor.sanitized(in: 1 ... 100, fallback: 1.5)
            self.upgradeHeadroom = upgradeHeadroom.sanitized(in: 1 ... 100, fallback: 1.25)
            self.upgradeDwellSeconds = upgradeDwellSeconds.sanitized(in: 0 ... 3_600, fallback: 4)
            self.lowPowerMaxLevel = max(0, lowPowerMaxLevel)
            self.seriousThermalMaxLevel = max(0, seriousThermalMaxLevel)
        }
    }

    public enum Change: Equatable, Sendable {
        case up(from: Int, to: Int)
        case down(from: Int, to: Int)
    }

    public let configuration: Configuration
    public private(set) var level: Int
    /// When the current up-switch condition started holding; `nil` when it
    /// does not hold.
    public private(set) var upgradeCandidateSince: Double?

    public init(configuration: Configuration = Configuration(), startLevel: Int = 0) {
        self.configuration = configuration
        let top = configuration.levelsKbps.count - 1
        self.level = min(max(0, startLevel), top)
    }

    private var topLevel: Int { configuration.levelsKbps.count - 1 }

    /// Current cap in kbps. `level` is always in `0 ... topLevel` (see `init`
    /// and `observe`), and `levelsKbps` is never empty, so the subscript is safe.
    public var capKbps: Int {
        configuration.levelsKbps[min(max(0, level), topLevel)]
    }

    /// Highest level throughput can sustain at `factor`; 0 when none can.
    public func sustainableLevel(throughputKbps: Int, factor: Double) -> Int {
        let throughput = Double(max(0, throughputKbps))
        var best = 0
        for (index, kbps) in configuration.levelsKbps.enumerated() where Double(kbps) * factor <= throughput {
            best = index
        }
        return best
    }

    /// Highest level device state allows, whatever the network says.
    public func ceiling(for conditions: DeviceConditions) -> Int {
        var ceiling = topLevel
        if conditions.lowPowerMode { ceiling = min(ceiling, configuration.lowPowerMaxLevel) }
        if conditions.thermal >= .serious { ceiling = min(ceiling, configuration.seriousThermalMaxLevel) }
        if conditions.thermal >= .critical { ceiling = 0 }
        return min(max(0, ceiling), topLevel)
    }

    /// Feeds one observation at monotonic time `now` (seconds). Returns the
    /// change it caused, if any. Non-finite times are treated as 0.
    @discardableResult
    public mutating func observe(_ conditions: DeviceConditions, at now: Double) -> Change? {
        let time = now.sanitized(in: -1e15 ... 1e15, fallback: 0)
        let ceiling = ceiling(for: conditions)
        let from = level

        // Offline: no throughput signal. Keep the level, but still obey the
        // device ceiling (a hot phone must drop quality even when offline).
        guard conditions.network != .offline else {
            upgradeCandidateSince = nil
            if level > ceiling {
                level = ceiling
                return .down(from: from, to: level)
            }
            return nil
        }

        let sustainable = min(sustainableLevel(throughputKbps: conditions.throughputKbps,
                                               factor: configuration.safetyFactor), ceiling)
        if sustainable < level {
            level = sustainable
            upgradeCandidateSince = nil
            return .down(from: from, to: level)
        }

        let upgradeTarget = min(sustainableLevel(throughputKbps: conditions.throughputKbps,
                                                 factor: configuration.safetyFactor * configuration.upgradeHeadroom),
                                ceiling)
        guard upgradeTarget > level else {
            upgradeCandidateSince = nil
            return nil
        }
        // A clock that went backwards restarts the dwell rather than
        // stretching it forever.
        let since = min(upgradeCandidateSince ?? time, time)
        upgradeCandidateSince = since
        guard time - since >= configuration.upgradeDwellSeconds else { return nil }
        level = min(level + 1, topLevel)
        // The next level needs a full dwell of its own.
        upgradeCandidateSince = time
        return .up(from: from, to: level)
    }
}

/// Measures switching behaviour of any ladder-like reducer over a trace.
public enum LadderAudit {
    /// Number of level changes `step` makes over `samples`.
    public static func switchCount<Sample>(samples: [Sample],
                                           step: (Sample) -> QualityLadder.Change?) -> Int {
        var count = 0
        for sample in samples where step(sample) != nil {
            Saturating.increment(&count)
        }
        return count
    }
}
