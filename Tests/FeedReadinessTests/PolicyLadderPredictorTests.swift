import XCTest
@testable import FeedReadiness

final class WindowPolicyTests: XCTestCase {
    func testDefaultPolicyIsMonotoneForDecoderCapacitiesZeroThroughEight() {
        for capacity in 0 ... 8 {
            let violations = PolicyAudit.monotonicityViolations(of: DefaultWindowPolicy(), decoderCapacity: capacity)
            XCTAssertEqual(violations, [], "capacity \(capacity): \(violations.prefix(3))")
            XCTAssertEqual(PolicyAudit.capacityViolations(of: DefaultWindowPolicy(), decoderCapacity: capacity), [])
        }
    }

    func testAuditCoversAllNinetySixCombinations() {
        XCTAssertEqual(PolicyAudit.allConditions.count, 4 * 4 * 3 * 2)
        XCTAssertEqual(Set(PolicyAudit.allConditions).count, 96)
    }

    /// A plausible-looking edit: offline only zeroes prefetch and forgets to
    /// inherit the constrained-network caps. Offline then prepares *more*
    /// than constrained does. The audit must catch it.
    func testAuditCatchesAPolicyWhereOfflineDoesNotInheritConstrainedCaps() {
        struct OfflineForgetsInheritance: WindowPolicy {
            func shape(for c: DeviceConditions, decoderCapacity: Int) -> WindowShape {
                var adjusted = c
                if c.network == .offline { adjusted.network = .wifi }
                let base = DefaultWindowPolicy().shape(for: adjusted, decoderCapacity: decoderCapacity)
                guard c.network == .offline else { return base }
                return WindowShape(preparedAhead: base.preparedAhead, preparedBehind: base.preparedBehind,
                                   prefetchAhead: 0, prefetchSeconds: base.prefetchSeconds,
                                   firstSegmentSeconds: base.firstSegmentSeconds)
            }
        }
        let violations = PolicyAudit.monotonicityViolations(of: OfflineForgetsInheritance(), decoderCapacity: 4)
        XCTAssertFalse(violations.isEmpty)
        XCTAssertTrue(violations.contains { $0.worse.network == .offline && $0.better.network == .constrained })
    }

    /// The subtle one: "thermal serious caps ahead at 1" without also zeroing
    /// "behind". With 3 decoders, ideal gets ahead 2 / behind 0 (the cap
    /// eats behind); serious gets ahead 1 / behind 1, so a *hotter* phone
    /// keeps an extra item warm behind the cursor.
    func testAuditCatchesBehindGrowingWhenAheadShrinks() {
        struct ThermalKeepsBehind: WindowPolicy {
            func shape(for c: DeviceConditions, decoderCapacity: Int) -> WindowShape {
                let base = DefaultWindowPolicy().baseline
                var ahead = base.preparedAhead
                var behind = base.preparedBehind
                if c.thermal >= .serious { ahead = min(ahead, 1) }
                let spare = max(0, decoderCapacity - 1)
                ahead = min(ahead, spare)
                behind = min(behind, spare - ahead)
                return WindowShape(preparedAhead: ahead, preparedBehind: behind, prefetchAhead: base.prefetchAhead,
                                   prefetchSeconds: base.prefetchSeconds, firstSegmentSeconds: base.firstSegmentSeconds)
            }
        }
        XCTAssertFalse(PolicyAudit.monotonicityViolations(of: ThermalKeepsBehind(), decoderCapacity: 3).isEmpty)
        XCTAssertEqual(PolicyAudit.monotonicityViolations(of: DefaultWindowPolicy(), decoderCapacity: 3), [])
    }

    func testCapacityAuditCatchesAPolicyThatIgnoresDecoderCount() {
        struct Greedy: WindowPolicy {
            func shape(for c: DeviceConditions, decoderCapacity: Int) -> WindowShape {
                WindowShape(preparedAhead: 3, preparedBehind: 1, prefetchAhead: 5, prefetchSeconds: 6, firstSegmentSeconds: 1)
            }
        }
        XCTAssertEqual(PolicyAudit.capacityViolations(of: Greedy(), decoderCapacity: 3).count, 96)
    }

    func testSpecificRules() {
        let policy = DefaultWindowPolicy()
        let ideal = policy.shape(for: .ideal, decoderCapacity: 4)
        XCTAssertEqual([ideal.preparedAhead, ideal.preparedBehind, ideal.prefetchAhead], [2, 1, 5])
        XCTAssertEqual(ideal.prefetchSeconds, 6)

        let cellular = policy.shape(for: DeviceConditions(network: .cellular), decoderCapacity: 4)
        XCTAssertEqual(cellular.prefetchAhead, 3)
        XCTAssertEqual(cellular.prefetchSeconds, 3)

        let offline = policy.shape(for: DeviceConditions(network: .offline), decoderCapacity: 4)
        XCTAssertEqual(offline.prefetchAhead, 0)
        XCTAssertEqual(offline.preparedAhead, 1)

        let hot = policy.shape(for: DeviceConditions(thermal: .critical), decoderCapacity: 4)
        XCTAssertEqual([hot.preparedAhead, hot.preparedBehind, hot.prefetchAhead], [0, 0, 1])

        let lowPower = policy.shape(for: DeviceConditions(lowPowerMode: true), decoderCapacity: 4)
        XCTAssertEqual([lowPower.preparedAhead, lowPower.preparedBehind, lowPower.prefetchAhead], [1, 0, 2])

        XCTAssertEqual(policy.shape(for: .ideal, decoderCapacity: 0).preparedAhead, 0)
        XCTAssertEqual(policy.shape(for: .ideal, decoderCapacity: 1).preparedAhead, 0)
        XCTAssertEqual(policy.shape(for: .ideal, decoderCapacity: -5).preparedBehind, 0)
    }

    func testHostileNumbersDoNotTrap() {
        let policy = DefaultWindowPolicy(baseline: WindowShape(preparedAhead: .max, preparedBehind: .max,
                                                               prefetchAhead: .max, prefetchSeconds: .infinity,
                                                               firstSegmentSeconds: .nan),
                                         maxWindow: .min)
        for capacity in [Int.min, -1, 0, 1, 4, Int.max] {
            let shape = policy.shape(for: .ideal, decoderCapacity: capacity)
            XCTAssertEqual(shape.preparedAhead, 0, "maxWindow clamps to 0")
            _ = DefaultWindowPolicy().shape(for: .ideal, decoderCapacity: capacity)
            XCTAssertEqual(PolicyAudit.capacityViolations(of: DefaultWindowPolicy(), decoderCapacity: capacity), [])
        }
        struct Huge: WindowPolicy {
            func shape(for c: DeviceConditions, decoderCapacity: Int) -> WindowShape {
                WindowShape(preparedAhead: .max, preparedBehind: .max, prefetchAhead: .max,
                            prefetchSeconds: 6, firstSegmentSeconds: 1)
            }
        }
        XCTAssertEqual(PolicyAudit.capacityViolations(of: Huge(), decoderCapacity: 4).count, 96)
        XCTAssertEqual(PolicyAudit.capacityViolations(of: Huge(), decoderCapacity: .min).count, 96)
    }

    func testShapeSanitisesNonFiniteSeconds() {
        let shape = WindowShape(preparedAhead: -1, preparedBehind: 1, prefetchAhead: 2,
                                prefetchSeconds: .nan, firstSegmentSeconds: .infinity)
        XCTAssertEqual(shape.preparedAhead, 0)
        XCTAssertEqual(shape.prefetchSeconds, 0)
        XCTAssertEqual(shape.firstSegmentSeconds, 0)
    }
}

final class QualityLadderTests: XCTestCase {
    private func sample(_ kbps: Int, _ thermal: ThermalLevel = .nominal, lowPower: Bool = false,
                        network: NetworkClass = .wifi) -> DeviceConditions {
        DeviceConditions(network: network, throughputKbps: kbps, lowPowerMode: lowPower, thermal: thermal)
    }

    func testDowngradeIsImmediateAndCanSkipLevels() {
        var ladder = QualityLadder(startLevel: 3)
        XCTAssertEqual(ladder.observe(sample(1_000), at: 0), .down(from: 3, to: 0))
        XCTAssertEqual(ladder.capKbps, 600)
    }

    func testUpgradeNeedsHeadroomAndFourSecondsAndMovesOneStep() {
        var ladder = QualityLadder()
        // 20 Mbps sustains the top level, but up-switches go one step per dwell.
        XCTAssertNil(ladder.observe(sample(20_000), at: 0))
        XCTAssertNil(ladder.observe(sample(20_000), at: 0), "a repeat at the same time is not progress")
        XCTAssertNil(ladder.observe(sample(20_000), at: 3.9))
        XCTAssertEqual(ladder.observe(sample(20_000), at: 4), .up(from: 0, to: 1))
        XCTAssertNil(ladder.observe(sample(20_000), at: 7.9), "the next level needs its own dwell")
        XCTAssertEqual(ladder.observe(sample(20_000), at: 8), .up(from: 1, to: 2))
        // A dip below the upgrade threshold (but still sustaining the level) resets the dwell.
        XCTAssertNil(ladder.observe(sample(4_000), at: 9))   // sustains 2.5 Mbps, cannot reach 5 Mbps
        XCTAssertNil(ladder.upgradeCandidateSince)
        XCTAssertNil(ladder.observe(sample(20_000), at: 10))
        XCTAssertNil(ladder.observe(sample(20_000), at: 13.9))
        XCTAssertEqual(ladder.observe(sample(20_000), at: 14), .up(from: 2, to: 3))
    }

    /// Throughput oscillating around the 2.5 Mbps level's thresholds, one
    /// sample a second: 3.6 Mbps cannot sustain 2.5 Mbps (needs 3.75), and
    /// 4.8 Mbps clears the upgrade bar (needs 4.69) but never for 4 seconds.
    /// The shipped ladder steps down once and stays; a ladder with no
    /// headroom and no dwell flips on every sample.
    func testOscillatingThroughputDoesNotFlapButANaiveLadderDoes() {
        let trace = (0 ..< 60).map { (sample($0.isMultiple(of: 2) ? 3_600 : 4_800), Double($0)) }
        var shipped = QualityLadder(startLevel: 2)
        let shippedSwitches = LadderAudit.switchCount(samples: trace) { shipped.observe($0.0, at: $0.1) }
        XCTAssertEqual(shippedSwitches, 1)

        var naive = QualityLadder(configuration: .init(upgradeHeadroom: 1, upgradeDwellSeconds: 0), startLevel: 2)
        let naiveSwitches = LadderAudit.switchCount(samples: trace) { naive.observe($0.0, at: $0.1) }
        XCTAssertGreaterThanOrEqual(naiveSwitches, 50, "the audit must be able to see flapping")
    }

    func testDeviceCeilingsOverrideThroughput() {
        var ladder = QualityLadder(startLevel: 3)
        XCTAssertEqual(ladder.observe(sample(50_000, .serious), at: 0), .down(from: 3, to: 1))
        XCTAssertEqual(ladder.observe(sample(50_000, .critical), at: 1), .down(from: 1, to: 0))
        var lowPower = QualityLadder(startLevel: 3)
        lowPower.observe(sample(50_000, lowPower: true), at: 0)
        XCTAssertEqual(lowPower.level, 1)
    }

    func testOfflineKeepsLevelButStillObeysThermal() {
        var ladder = QualityLadder(startLevel: 2)
        XCTAssertNil(ladder.observe(sample(0, network: .offline), at: 0))
        XCTAssertEqual(ladder.level, 2)
        XCTAssertEqual(ladder.observe(sample(0, .critical, network: .offline), at: 1), .down(from: 2, to: 0))
    }

    func testHostileTimesAndConfigurationsStayInRange() {
        let empty = QualityLadder(configuration: .init(levelsKbps: [], safetyFactor: .nan, upgradeDwellSeconds: -3),
                                  startLevel: 99)
        XCTAssertEqual(empty.level, 0)
        XCTAssertEqual(empty.capKbps, .max)
        var ladder = QualityLadder(configuration: .init(levelsKbps: [800, 800, -1, 200]), startLevel: -4)
        XCTAssertEqual(ladder.configuration.levelsKbps, [200, 800])
        XCTAssertEqual(ladder.level, 0)
        for step in 0 ..< 10 { ladder.observe(sample(.max), at: Double(step) * 5) }
        XCTAssertEqual(ladder.level, 1)
        // Non-finite times are read as 0: they never trap and, repeated,
        // never add up to a dwell.
        var clockless = QualityLadder()
        for time in [Double.nan, .infinity, -.infinity, .nan, .nan] {
            clockless.observe(sample(20_000), at: time)
        }
        XCTAssertEqual(clockless.level, 0)
        // Huge and backwards times do not trap either.
        for time in [1e300, -1e300, 5, 1] { clockless.observe(sample(20_000), at: time) }
        XCTAssertTrue((0 ... 3).contains(clockless.level))
    }
}

final class SkipPredictorTests: XCTestCase {
    func testUntrainedModelIsExactlyUndecided() {
        XCTAssertEqual(SkipPredictor().skipProbability, 0.5, accuracy: 1e-12)
    }

    func testLearnsASkipperAndAWatcher() {
        var skipper = SkipPredictor()
        var watcher = SkipPredictor()
        for _ in 0 ..< 20 {
            skipper.learn(.init(watchFraction: 0.05, swipeVelocity: 2_500))
            watcher.learn(.init(watchFraction: 0.95, swipeVelocity: 300))
        }
        XCTAssertGreaterThan(skipper.skipProbability, 0.8)
        XCTAssertLessThan(watcher.skipProbability, 0.2)
    }

    /// Proves the test above is not vacuous: the same training with a
    /// plausible bug in the learning step (the gradient's sign flipped, i.e.
    /// ascent instead of descent) must fail both thresholds.
    func testABrokenLearningRuleFailsTheThresholds() {
        let ascent: SkipPredictor.LearningRule = { weights, features, error, rate in
            weights.indices.map { i in i < features.count ? weights[i] - rate * error * features[i] : weights[i] }
        }
        var skipper = SkipPredictor(rule: ascent)
        var watcher = SkipPredictor(rule: ascent)
        for _ in 0 ..< 20 {
            skipper.learn(.init(watchFraction: 0.05, swipeVelocity: 2_500))
            watcher.learn(.init(watchFraction: 0.95, swipeVelocity: 300))
        }
        XCTAssertFalse(skipper.skipProbability > 0.8)
        XCTAssertFalse(watcher.skipProbability < 0.2)
    }

    /// A rule that returns garbage cannot corrupt the model's bounds.
    func testWeightsStayBoundedWhateverTheRuleReturns() {
        var model = SkipPredictor(rule: { _, _, _, _ in [.nan, .infinity, -.infinity] })
        model.learn(.init(watchFraction: 0.1, swipeVelocity: 100))
        XCTAssertEqual(model.weights.count, 4)
        XCTAssertTrue(model.weights.allSatisfy { $0.isFinite && abs($0) <= SkipPredictor.weightBound })
        XCTAssertTrue(model.skipProbability.isFinite)
    }

    func testAdaptsWhenBehaviourChanges() {
        var model = SkipPredictor()
        for _ in 0 ..< 20 { model.learn(.init(watchFraction: 0.05, swipeVelocity: 2_500)) }
        XCTAssertGreaterThan(model.skipProbability, 0.8)
        for _ in 0 ..< 30 { model.learn(.init(watchFraction: 0.95, swipeVelocity: 200)) }
        XCTAssertLessThan(model.skipProbability, 0.5)
    }

    func testNonFiniteInputsCannotPoisonTheModel() {
        var model = SkipPredictor(learningRate: 1_000)
        for value in [Double.nan, .infinity, -.infinity, 1e308] {
            model.learn(.init(watchFraction: value, swipeVelocity: value))
        }
        XCTAssertTrue(model.skipProbability.isFinite)
        XCTAssertTrue(model.weights.allSatisfy { $0.isFinite && abs($0) <= SkipPredictor.weightBound })
        XCTAssertGreaterThan(model.skipProbability, 0)
        XCTAssertLessThan(model.skipProbability, 1)
    }

    func testHistoryIsBounded() {
        var model = SkipPredictor(historyLimit: 3)
        for i in 0 ..< 100 { model.learn(.init(watchFraction: Double(i % 10) / 10, swipeVelocity: 100)) }
        XCTAssertEqual(model.history.count, 3)
        XCTAssertEqual(model.observations, 100)
    }
}
