import XCTest
@testable import FeedReadiness

/// Safeguards that no fault switch covers. Each test here exists because a
/// one-line mutation of `FeedEngine` survived the rest of the suite (found by
/// the final independent review); each one fails on that mutation.
final class EngineGuardTests: XCTestCase {
    /// A cancelled top-up shrinks back to the bytes delivered before it, not to
    /// zero (README design decision 7). Kills: `cancelFetch` shrinking to 0.
    func testCancelledTopUpKeepsTheBytesAlreadyOnDisk() async {
        let transport = GatedTransport()
        let engine = makeEngine(conditions: DeviceConditions(network: .cellular), transport: transport)
        await engine.start()                                   // v1–v3, 3 s each on cellular
        let firstFetches = await waitUntilWaiting(transport, count: 3)
        XCTAssertTrue(firstFetches)
        await transport.release(first: 3)
        await engine.waitUntilIdle()
        await engine.update(conditions: .ideal)                // top-ups to 6 s, held at the gate
        let topUps = await waitUntilWaiting(transport, count: 3)
        XCTAssertTrue(topUps)
        await engine.update(conditions: DeviceConditions(network: .offline)) // cancels every download
        let snap = await engine.snapshot()
        await transport.openAll()
        await engine.waitUntilIdle()
        XCTAssertEqual(snap.rows.first { $0.index == 3 }?.cachedSeconds ?? 0, 3, accuracy: 1e-9,
                       "the 3 s delivered before the top-up survive its cancellation")
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    /// A failed top-up also keeps the bytes delivered before it. Kills: the
    /// failure path of `fetchFinished` shrinking to 0.
    func testFailedTopUpKeepsTheBytesAlreadyOnDisk() async {
        // Fetches 1–3 (v1–v3 on cellular) succeed; the 4th, the first top-up, fails.
        let engine = makeEngine(conditions: DeviceConditions(network: .cellular),
                                transport: SimulatedTransport(failEvery: 4))
        await engine.start()
        await engine.waitUntilIdle()
        await engine.update(conditions: .ideal)
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        XCTAssertGreaterThan(snap.stats.prefetchesFailed, 0)
        let seconds = (1 ... 3).map { index in snap.rows.first { $0.index == index }?.cachedSeconds ?? 0 }
        XCTAssertTrue(seconds.allSatisfy { $0 >= 3 - 1e-9 }, "\(seconds)")
    }

    /// When the pool is full, a hand-off pre-empts the lowest-priority ready
    /// decoder (+2), never the next clip (+1). Kills: picking the victim from
    /// the front of the plan's prepared list instead of the back.
    func testHandOffPreemptsTheLowestPriorityDecoder() async {
        var items = (0 ..< 10).map {
            FeedItem(id: ItemID("v\($0)"), renditions: [Fixtures.ladder[1]], durationSeconds: 20)
        }
        items[2] = Fixtures.feed(3)[2]                          // only v2 has a quality ladder
        let player = SimulatedPlayer()
        let engine = makeEngine(items: items, capacity: 4, player: player)
        await engine.start()
        await engine.move(to: 2)
        await engine.waitUntilIdle()
        await player.holdPrepares()
        await engine.update(conditions: DeviceConditions(throughputKbps: 3_000)) // v2: 1080p → 540p
        let replacementWaiting = await waitUntilPlayer(player, seconds: 3) { $0 >= 1 }
        XCTAssertTrue(replacementWaiting)
        let during = await engine.snapshot()
        XCTAssertEqual(during.rows.first { $0.index == 3 }?.decoder, .ready, "the next clip keeps its decoder")
        XCTAssertNotEqual(during.rows.first { $0.index == 4 }?.decoder, .ready, "the farthest one is pre-empted")
        await player.openPrepares()
        await engine.waitUntilIdle()
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    /// With room for more than one decoder, a full pool whose other decoders
    /// are still preparing makes the hand-off wait for one of them; it must
    /// not blank the screen. Kills: falling back to break-before-make
    /// whenever no prepared decoder is ready.
    func testHandOffWaitsInsteadOfBreakingWhileOthersArePreparing() async {
        var items = (0 ..< 10).map {
            FeedItem(id: ItemID("v\($0)"), renditions: [Fixtures.ladder[1]], durationSeconds: 20)
        }
        items[2] = Fixtures.feed(3)[2]
        let player = SimulatedPlayer()
        let engine = makeEngine(items: items, capacity: 3, player: player)
        await engine.start()
        await engine.waitUntilIdle()
        await player.holdPrepares()
        await engine.move(to: 2)                                // v3 and v4 prepare, held at the gate
        let neighboursPreparing = await waitUntilPlayer(player, seconds: 3) { $0 >= 2 }
        XCTAssertTrue(neighboursPreparing)
        await engine.update(conditions: DeviceConditions(throughputKbps: 3_000))
        // The mutant decides synchronously inside `update`; the short wait
        // only lets its pause reach the player, so the check below is not
        // timing-sensitive for the shipped code (nothing happens meanwhile).
        try? await Task.sleep(for: .milliseconds(50))
        let during = await player.currentReport()
        let snap = await engine.snapshot()
        XCTAssertEqual(during.playing.map(\.key), [DecoderKey(item: "v2", rendition: "1080")],
                       "the old rendition keeps playing while the hand-off waits")
        XCTAssertEqual(snap.stats.breakBeforeMakeFallbacks, 0)
        await player.openPrepares()
        await engine.waitUntilIdle()
        let after = await player.currentReport()
        XCTAssertEqual(after.playing.map(\.key), [DecoderKey(item: "v2", rendition: "540")])
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }
}
