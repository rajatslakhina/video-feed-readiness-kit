import XCTest
import FeedReadiness // plain import: the README snippet must work for a client

/// The README's usage snippets, compiled and run as written (only the
/// placeholders are bound to simulated ports). If the public API drifts,
/// this file stops compiling before the README goes stale.
final class ReadmeUsageTests: XCTestCase {
    func testReadmeUsageSnippetCompilesAndRuns() async {
        let feedItems = (0 ..< 10).map {
            FeedItem(id: ItemID("clip-\($0)"),
                     renditions: [Rendition(id: "540", height: 540, bitrateKbps: 1_200),
                                  Rendition(id: "1080", height: 1_080, bitrateKbps: 5_000)],
                     durationSeconds: 20)
        }
        let myAVPlayerAdapter = SimulatedPlayer()
        let myURLSessionPrefetcher = SimulatedTransport()
        let current = DeviceConditions(network: .cellular, throughputKbps: 3_000)

        // --- README "Usage" snippet (keep in sync with README.md) ---
        let engine = FeedEngine(
            items: feedItems,                                  // [FeedItem] with their renditions
            conditions: DeviceConditions(network: .wifi, throughputKbps: 12_000),
            configuration: .init(decoderCapacity: 4, cacheBudgetBytes: 48 << 20),
            player: myAVPlayerAdapter,                         // conforms to PlayerPort
            transport: myURLSessionPrefetcher                  // conforms to PrefetchTransport
        )
        await engine.start()

        // On every swipe: tell it what you learned about the clip being left.
        await engine.move(by: 1, leaving: .init(watchFraction: 0.12, swipeVelocity: 2_400))

        // On NWPathMonitor / thermal / Low Power notifications, and on each
        // new throughput estimate from your network layer:
        await engine.update(conditions: current)

        // Debug builds: check the books balance.
        let problems = await engine.invariantViolations()
        assert(problems.isEmpty, "\(problems)")
        // --- end of snippet ---

        await engine.waitUntilIdle()
        XCTAssertTrue(problems.isEmpty)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursor, 1)
        // A fresh engine starts on the lowest rung (default `startLevel: 0`) and
        // only climbs after 4 s of sustained headroom, which this test never waits.
        XCTAssertEqual(snap.qualityCapKbps, 600)
    }

    func testReadmePlannerSnippetCompiles() {
        let items = (0 ..< 5).map {
            FeedItem(id: ItemID("clip-\($0)"), renditions: [Rendition(id: "540", height: 540, bitrateKbps: 1_200)],
                     durationSeconds: 20)
        }
        let input = PlannerInput(items: items, cursor: 0,
                                 shape: DefaultWindowPolicy().shape(for: .ideal, decoderCapacity: 4),
                                 decoderCapacity: 4, qualityCapKbps: 5_000, network: .wifi)
        // --- README planner snippet ---
        let plan = ReadinessPlanner().plan(input)
        assert(ReadinessInvariants.violations(of: plan, for: input).isEmpty)
        // --- end of snippet ---
        XCTAssertEqual(plan.playing?.item, "clip-0")
    }
}
