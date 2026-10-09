import XCTest
@testable import FeedReadiness

final class PlannerTests: XCTestCase {
    let planner = ReadinessPlanner()

    func testEmptyFeedProducesAnEmptyPlan() {
        let input = Fixtures.input(items: [])
        let plan = planner.plan(input)
        XCTAssertEqual(plan.diagnostics, [.emptyFeed])
        XCTAssertNil(plan.playing)
        XCTAssertEqual(ReadinessInvariants.violations(of: plan, for: input), [])
    }

    func testIdealWindowAroundTheCursor() {
        let input = Fixtures.input(items: Fixtures.feed(20), cursor: 5)
        let plan = planner.plan(input)
        XCTAssertEqual(plan.playing?.index, 5)
        XCTAssertEqual(plan.prepared.map(\.index), [6, 4, 7], "nearest first, ahead before behind")
        XCTAssertEqual(plan.prefetch.map(\.index), [6, 7, 8, 9, 10])
        XCTAssertEqual(plan.prefetch.first?.targetBytes, Fixtures.ladder[3].bytes(forSeconds: 6))
        XCTAssertEqual(plan.tier(at: 5), .playing)
        XCTAssertEqual(plan.tier(at: 4), .prepared)
        XCTAssertEqual(plan.tier(at: 9), .prefetched)
        XCTAssertEqual(plan.tier(at: 11), .cold)
        XCTAssertEqual(ReadinessInvariants.violations(of: plan, for: input), [])
    }

    func testCursorOutOfRangeIsClampedAndReported() {
        let input = Fixtures.input(items: Fixtures.feed(3), cursor: 99)
        let plan = planner.plan(input)
        XCTAssertEqual(plan.cursor, 2)
        XCTAssertTrue(plan.diagnostics.contains(.cursorClamped(requested: 99, used: 2)))
        XCTAssertEqual(plan.prefetch, [], "nothing ahead of the last item")
        XCTAssertEqual(plan.prepared.map(\.index), [1], "one behind; nothing ahead of the end")
        XCTAssertEqual(planner.plan(Fixtures.input(items: Fixtures.feed(3), cursor: Int.min)).cursor, 0)
    }

    func testOneDecoderMeansPlaybackOnlyAndZeroMeansNothing() {
        let one = planner.plan(Fixtures.input(items: Fixtures.feed(10), capacity: 1))
        XCTAssertNotNil(one.playing)
        XCTAssertEqual(one.prepared, [])
        let zero = planner.plan(Fixtures.input(items: Fixtures.feed(10), capacity: 0))
        XCTAssertNil(zero.playing)
        XCTAssertTrue(zero.diagnostics.contains(.noDecoderForPlayback))
    }

    /// The planner enforces the decoder budget itself rather than trusting
    /// the policy: a custom policy can return any shape.
    func testPlannerCapsPreparedAtSpareDecodersWhateverTheShapeSays() {
        var input = Fixtures.input(items: Fixtures.feed(20), cursor: 10, capacity: 3)
        input.shape = WindowShape(preparedAhead: 5, preparedBehind: 5, prefetchAhead: 2,
                                  prefetchSeconds: 6, firstSegmentSeconds: 1)
        let plan = planner.plan(input)
        XCTAssertEqual(plan.prepared.map(\.index), [11, 9])
        input.shape = WindowShape(preparedAhead: .max, preparedBehind: .max, prefetchAhead: .max,
                                  prefetchSeconds: 6, firstSegmentSeconds: 1)
        let huge = planner.plan(input)
        XCTAssertEqual(huge.prepared.count, 2)
        XCTAssertEqual(huge.prefetch.map(\.index), Array(11 ... 19), "bounded by the feed, not the shape")
        XCTAssertEqual(ReadinessInvariants.violations(of: huge, for: input), [])
    }

    func testUnplayableItemsAreSkippedNotCrashedOn() {
        var items = Fixtures.feed(6)
        items[1] = FeedItem(id: "broken", renditions: [], durationSeconds: 10)
        items[0] = FeedItem(id: "also-broken", renditions: [], durationSeconds: 10)
        let input = Fixtures.input(items: items, cursor: 0)
        let plan = planner.plan(input)
        XCTAssertNil(plan.playing)
        XCTAssertTrue(plan.diagnostics.contains(.unplayable("also-broken")))
        XCTAssertFalse(plan.prepared.contains { $0.item == "broken" })
        XCTAssertFalse(plan.prefetch.contains { $0.key.item == "broken" })
        XCTAssertEqual(ReadinessInvariants.violations(of: plan, for: input), [])
    }

    func testLikelySkipShortensPrefetchToTheFirstSegment() {
        let items = Fixtures.feed(10)
        let watcher = planner.plan(Fixtures.input(items: items, skip: 0.2))
        let skipper = planner.plan(Fixtures.input(items: items, skip: 0.9))
        let r = Fixtures.ladder[3]
        XCTAssertEqual(watcher.prefetch.first?.targetBytes, r.bytes(forSeconds: 6))
        XCTAssertEqual(skipper.prefetch.first?.targetBytes, r.bytes(forSeconds: 1.5))
        XCTAssertTrue(skipper.prefetch.allSatisfy(\.shortenedForLikelySkip))
        let saved = watcher.prefetch.reduce(Int64(0)) { $0 + $1.targetBytes }
            - skipper.prefetch.reduce(Int64(0)) { $0 + $1.targetBytes }
        XCTAssertEqual(saved, 5 * (r.bytes(forSeconds: 6) - r.bytes(forSeconds: 1.5)))
    }

    func testPrefetchNeverExceedsTheItemAndSkipsWhatIsCached() {
        let items = Fixtures.feed(4, duration: 2) // 2 s items, 6 s prefetch window
        let key1 = CacheKey(item: "v1", rendition: "1080")
        let input = Fixtures.input(items: items, committed: [key1: Fixtures.ladder[3].bytes(forSeconds: 2)])
        let plan = planner.plan(input)
        XCTAssertFalse(plan.prefetch.contains { $0.key == key1 }, "fully cached: no request")
        XCTAssertEqual(plan.tier(at: 1), .prepared)
        XCTAssertEqual(plan.prefetchWindow.map(\.index), [1, 2, 3], "cached items are still inside the window")
        XCTAssertTrue(plan.pinnedKeys.contains(key1), "and their bytes stay pinned")
        XCTAssertEqual(plan.prefetch.first?.targetBytes, Fixtures.ladder[3].bytes(forSeconds: 2))
        XCTAssertEqual(ReadinessInvariants.violations(of: plan, for: input), [])
    }

    func testOfflinePreparesOnlyFromCachedBytesAndPrefetchesNothing() {
        let items = Fixtures.feed(6)
        let first = Fixtures.ladder[1].bytes(forSeconds: 1.5)
        let committed: [CacheKey: Int64] = [
            CacheKey(item: "v0", rendition: "540"): first,
            CacheKey(item: "v1", rendition: "540"): first,
            CacheKey(item: "v2", rendition: "540"): first - 1, // one byte short
        ]
        let input = Fixtures.input(items: items, conditions: DeviceConditions(network: .offline), committed: committed)
        let plan = planner.plan(input)
        XCTAssertEqual(plan.playing?.rendition.id, "540", "best *cached* rendition, not best overall")
        XCTAssertEqual(plan.prepared.map(\.item), ["v1"])
        XCTAssertEqual(plan.prefetch, [])
        XCTAssertEqual(ReadinessInvariants.violations(of: plan, for: input), [])
    }

    /// A window position that is already fully cached needs no request, but
    /// its bytes must still be pinned, or the next reservation could evict
    /// exactly the clip the user is about to reach.
    func testFullyCachedWindowItemsStayPinned() {
        let items = Fixtures.feed(10, duration: 2)
        let key4 = CacheKey(item: "v4", rendition: "1080")
        let input = Fixtures.input(items: items, committed: [key4: Fixtures.ladder[3].bytes(forSeconds: 2)])
        let plan = planner.plan(input)
        XCTAssertFalse(plan.slots.contains { $0.item == "v4" }, "v4 is prefetch-only, not a decoder slot")
        XCTAssertFalse(plan.prefetch.contains { $0.key == key4 }, "and needs no request")
        XCTAssertEqual(plan.tier(at: 4), .prefetched)
        XCTAssertTrue(plan.pinnedKeys.contains(key4))
        XCTAssertFalse(plan.pinnedKeys.contains(CacheKey(item: "v4", rendition: "360")), "other renditions are not pinned")
    }

    /// Offline, a clip whose player is already prepared keeps its slot even
    /// with nothing in the prefetch cache: its player buffered the start.
    func testOfflineKeepsAlreadyPreparedDecoders() {
        var input = Fixtures.input(items: Fixtures.feed(6), conditions: DeviceConditions(network: .offline))
        input.preparedDecoders = [DecoderKey(item: "v0", rendition: "1080"), DecoderKey(item: "v1", rendition: "1080")]
        let plan = planner.plan(input)
        XCTAssertEqual(plan.playing?.item, "v0")
        XCTAssertEqual(plan.prepared.map(\.item), ["v1"])
        input.preparedDecoders = []
        XCTAssertNil(planner.plan(input).playing, "without a prepared player or cached bytes nothing can start")
    }

    /// Offline, a quality ceiling (Low Power, heat) must not stop a clip
    /// that can play: with nothing startable under the cap, the lowest
    /// startable rendition above it is used.
    func testOfflineCapIsAPreferenceNotARefusal() {
        var input = Fixtures.input(items: Fixtures.feed(6), conditions: DeviceConditions(network: .offline), cap: 1_200)
        input.preparedDecoders = [DecoderKey(item: "v0", rendition: "1080")]
        input.committedBytes = [
            CacheKey(item: "v1", rendition: "720"): Fixtures.ladder[2].bytes(forSeconds: 6),
            CacheKey(item: "v1", rendition: "1080"): Fixtures.ladder[3].bytes(forSeconds: 6),
        ]
        let plan = planner.plan(input)
        XCTAssertEqual(plan.playing?.rendition.id, "1080", "the prepared player keeps playing above the cap")
        XCTAssertEqual(plan.prepared.first?.rendition.id, "720", "lowest startable rendition above the cap")
        XCTAssertEqual(ReadinessInvariants.violations(of: plan, for: input), [])

        // The checker rejects going above the cap when something under it could start.
        input.committedBytes[CacheKey(item: "v1", rendition: "540")] = Fixtures.ladder[1].bytes(forSeconds: 6)
        let better = planner.plan(input)
        XCTAssertEqual(better.prepared.first?.rendition.id, "540")
        var wrong = better
        wrong.prepared = [PlannedSlot(index: 1, item: "v1", rendition: Fixtures.ladder[2])]
        XCTAssertFalse(ReadinessInvariants.violations(of: wrong, for: input).isEmpty)
        // And planning a rendition that cannot start offline.
        var unstartable = better
        unstartable.prepared = [PlannedSlot(index: 1, item: "v1", rendition: Fixtures.ladder[0])]
        XCTAssertFalse(ReadinessInvariants.violations(of: unstartable, for: input).isEmpty)
    }

    func testExtremeCapacitiesDoNotTrap() {
        for capacity in [Int.min, -1, 0, 1, Int.max] {
            let input = Fixtures.input(items: Fixtures.feed(8), cursor: 3, capacity: capacity)
            let plan = planner.plan(input)
            XCTAssertEqual(ReadinessInvariants.violations(of: plan, for: input), [], "capacity \(capacity)")
        }
    }

    func testQualityCapSelectsRenditions() {
        let plan = planner.plan(Fixtures.input(items: Fixtures.feed(5), cap: 1_200))
        XCTAssertTrue(([plan.playing].compactMap { $0 } + plan.prepared).allSatisfy { $0.rendition.id == "540" })
        XCTAssertTrue(plan.prefetch.allSatisfy { $0.key.rendition == "540" })
    }

    func testDuplicateItemIDsNeverHoldTwoDecoders() {
        let base = Fixtures.feed(3)
        let items = [base[0], base[1], base[0], base[1], base[2]]
        let input = Fixtures.input(items: items, cursor: 2)
        let plan = planner.plan(input)
        XCTAssertEqual(ReadinessInvariants.violations(of: plan, for: input), [])
    }

    /// 5,000 random inputs (feeds with holes, every condition, odd
    /// capacities, cursors far out of range, random cache state).
    func testRandomInputsNeverViolateInvariants() {
        var rng = SplitMix64(seed: 2026)
        for _ in 0 ..< 5_000 {
            let count = Int.random(in: 0 ... 30, using: &rng)
            var items = Fixtures.feed(count, duration: Double.random(in: 0 ... 30, using: &rng))
            for i in items.indices where Int.random(in: 0 ..< 8, using: &rng) == 0 {
                items[i] = FeedItem(id: items[i].id, renditions: [], durationSeconds: 5)
            }
            let conditions = PolicyAudit.allConditions.randomElement(using: &rng) ?? .ideal
            var committed: [CacheKey: Int64] = [:]
            for item in items where Bool.random(using: &rng) {
                committed[CacheKey(item: item.id, rendition: ["360", "540"].randomElement(using: &rng) ?? "360")] =
                    Int64.random(in: 0 ... 2_000_000, using: &rng)
            }
            let input = Fixtures.input(items: items, cursor: Int.random(in: -5 ... 40, using: &rng),
                                       capacity: Int.random(in: -1 ... 6, using: &rng), conditions: conditions,
                                       cap: [0, 600, 1_200, 2_500, 5_000, .max].randomElement(using: &rng) ?? 600,
                                       skip: Double.random(in: 0 ... 1, using: &rng), committed: committed)
            var shaped = input
            if Bool.random(using: &rng) {
                // Shapes no shipped policy would produce, to exercise the
                // planner's own bounds rather than the policy's.
                shaped.shape = WindowShape(preparedAhead: Int.random(in: 0 ... 12, using: &rng),
                                           preparedBehind: Int.random(in: 0 ... 12, using: &rng),
                                           prefetchAhead: Int.random(in: 0 ... 40, using: &rng),
                                           prefetchSeconds: Double.random(in: 0 ... 40, using: &rng),
                                           firstSegmentSeconds: Double.random(in: 0 ... 5, using: &rng))
            }
            let plan = planner.plan(shaped)
            let violations = ReadinessInvariants.violations(of: plan, for: shaped)
            XCTAssertEqual(violations, [], "\(violations)")
            if !violations.isEmpty { return }
        }
    }

    /// The invariant checker is what the fuzz test trusts, so it must
    /// reject plans that are actually wrong. Each case breaks one rule.
    func testInvariantCheckerRejectsHandBrokenPlans() {
        let items = Fixtures.feed(10)
        let input = Fixtures.input(items: items, cursor: 3, capacity: 3)
        let good = planner.plan(input)
        XCTAssertEqual(ReadinessInvariants.violations(of: good, for: input), [])
        let r = Fixtures.ladder[3]

        var overCapacity = good
        overCapacity.prepared.append(PlannedSlot(index: 5, item: "v5", rendition: r))
        var duplicate = good
        if let playing = good.playing { duplicate.prepared = [playing] }
        var outsideWindow = good
        outsideWindow.prepared = [PlannedSlot(index: 9, item: "v9", rendition: r)]
        var wrongIndex = good
        wrongIndex.prepared = [PlannedSlot(index: 4, item: "v7", rendition: r)]
        var prefetchBehind = good
        prefetchBehind.prefetch.append(PrefetchRequest(index: 1, key: CacheKey(item: "v1", rendition: "1080"),
                                                       targetBytes: 10, shortenedForLikelySkip: false))
        var tooBig = good
        tooBig.prefetch = [PrefetchRequest(index: 4, key: CacheKey(item: "v4", rendition: "1080"),
                                           targetBytes: .max, shortenedForLikelySkip: false)]
        var windowBehind = good
        windowBehind.prefetchWindow.append(WindowEntry(index: 0, key: CacheKey(item: "v0", rendition: "1080")))
        var hugeIndex = good
        hugeIndex.prepared = [PlannedSlot(index: .min, item: "v0", rendition: r)]
        hugeIndex.prefetch = [PrefetchRequest(index: .max, key: CacheKey(item: "v4", rendition: "1080"),
                                              targetBytes: 1, shortenedForLikelySkip: false)]
        var wrongCursor = good
        wrongCursor.cursor = 4
        var overCap = good
        let capped = Fixtures.input(items: items, cursor: 3, capacity: 3, cap: 600)
        overCap.prepared = [PlannedSlot(index: 4, item: "v4", rendition: r)]

        let cases: [(String, ReadinessPlan, PlannerInput)] = [
            ("overCapacity", overCapacity, input), ("duplicate", duplicate, input),
            ("outsideWindow", outsideWindow, input), ("wrongIndex", wrongIndex, input),
            ("prefetchBehind", prefetchBehind, input), ("tooBig", tooBig, input),
            ("windowBehind", windowBehind, input), ("hugeIndex", hugeIndex, input),
            ("wrongCursor", wrongCursor, input), ("overCap", overCap, capped),
        ]
        XCTAssertEqual(cases.count, 10)
        for (name, plan, against) in cases {
            XCTAssertFalse(ReadinessInvariants.violations(of: plan, for: against).isEmpty, name)
        }
    }
}
