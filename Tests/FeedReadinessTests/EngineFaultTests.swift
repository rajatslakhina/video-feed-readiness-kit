import XCTest
@testable import FeedReadiness

/// Each test switches off exactly one engine safeguard (see
/// `FeedEngine.FaultInjection`) and runs the scenario its guarding test
/// uses, asserting that the check now *fails*. Without these, a check that
/// can never fail would read like coverage.
final class EngineFaultTests: XCTestCase {
    /// Guard: whoever finishes last releases.
    /// Check: `testFlingNeverOvercommitsDecodersOrReleasesMidPrepare`.
    func testReleasingWhilePreparingIsCaught() async {
        let player = SimulatedPlayer(prepareLatency: .milliseconds(80))
        let engine = makeEngine(capacity: 4, player: player, faults: .releaseWhilePreparing)
        await engine.start()
        for step in 1 ... 20 { await engine.move(to: step * 2) }
        await engine.waitUntilIdle()
        let report = await player.currentReport()
        XCTAssertGreaterThan(report.releasesDuringPrepare, 0)
        XCTAssertGreaterThan(report.leakedDecoders, 0)
        XCTAssertGreaterThan(report.maxLiveDecoders, 4, "the hardware was over-committed")
    }

    /// Guard: play/pause/release go through one FIFO chain.
    /// Check: at most one clip playing (`testRapidSwipes…`).
    /// With a slow `pause`, an unordered `play(next)` overtakes `pause(previous)`.
    func testUnorderedPortCommandsAreCaught() async {
        let player = SimulatedPlayer(pauseLatency: .milliseconds(40))
        let engine = makeEngine(player: player, faults: .unorderedPortCommands)
        await engine.start()
        await engine.waitUntilIdle()
        await engine.move(to: 1)
        await engine.waitUntilIdle()
        let report = await player.currentReport()
        XCTAssertGreaterThan(report.maxSimultaneouslyPlaying, 1, "two clips played at once")

        // Same scenario, shipped engine: never two at once.
        let orderedPlayer = SimulatedPlayer(pauseLatency: .milliseconds(40))
        let ordered = makeEngine(player: orderedPlayer)
        await ordered.start()
        await ordered.waitUntilIdle()
        await ordered.move(to: 1)
        await ordered.waitUntilIdle()
        let orderedReport = await orderedPlayer.currentReport()
        XCTAssertEqual(orderedReport.maxSimultaneouslyPlaying, 1)
        XCTAssertEqual(orderedReport.playing.map(\.key.item), ["v1"])
    }

    /// Guard: fetch completions are matched by token.
    /// Check: `testStaleFetchCompletionCannotCorruptAReRequest`.
    func testAcceptingStaleFetchCompletionsIsCaught() async {
        let transport = GatedTransport()
        let engine = makeEngine(transport: transport, faults: .acceptStaleFetchCompletions)
        await engine.start()
        _ = await waitUntilWaiting(transport, count: 5)
        await engine.move(to: 30)
        _ = await waitUntilWaiting(transport, count: 10)
        await engine.move(to: 0)
        _ = await waitUntilWaiting(transport, count: 15)
        await transport.release(first: 10)
        _ = await waitUntil(engine, seconds: 5) { $0.stats.staleFetchCompletions + $0.stats.prefetchesFailed >= 10 }
        await transport.openAll()
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        // Each of the five late v1-v5 completions (failed: their tasks were
        // cancelled) was applied to the *new* v1-v5 downloads, discarding
        // them. The shipped engine records 0 failures in the same sequence.
        XCTAssertGreaterThanOrEqual(snap.stats.prefetchesFailed, 5, "old cancellations were applied to new downloads")
    }

    /// Guard: make-before-break on a rendition switch.
    /// Check: `testQualityDowngradeIsMakeBeforeBreak`.
    func testBreakBeforeMakeIsCaught() async {
        let player = SimulatedPlayer()
        let engine = makeEngine(player: player, faults: .breakBeforeMake)
        await engine.start()
        await engine.waitUntilIdle()
        await player.holdPrepares()
        await engine.update(conditions: DeviceConditions(throughputKbps: 3_000))
        _ = await waitUntilPlayer(player, seconds: 3) { $0 >= 1 }
        var blank = false
        for _ in 0 ..< 300 where !blank {
            blank = await player.currentReport().playing.isEmpty
            if !blank { try? await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(blank, "the screen went blank while the new rendition prepared")
        await player.openPrepares()
        await engine.waitUntilIdle()
    }

    /// Guard: a hand-off that cannot get a slot pre-empts (or falls back).
    /// Check: the settled-playback rule in `invariantViolations()`, which
    /// every engine test asserts is empty.
    func testAStalledHandOffIsReportedByTheInvariantChecker() async {
        let player = SimulatedPlayer()
        let engine = makeEngine(capacity: 1, player: player, faults: .noHandOffPreemption)
        await engine.start()
        await engine.waitUntilIdle()
        await engine.update(conditions: DeviceConditions(thermal: .critical))
        await engine.waitUntilIdle()
        let report = await player.currentReport()
        XCTAssertEqual(report.playing.map(\.key), [DecoderKey(item: "v0", rendition: "1080")],
                       "stuck on the old rendition")
        let problems = await engine.invariantViolations()
        XCTAssertTrue(problems.contains { $0.contains("settled with") }, "\(problems)")
    }

    /// Guard: the engine's own books (pool vs held vs releasing).
    /// Check: `invariantViolations()` itself, asserted empty by most engine tests.
    func testCorruptBooksAreReportedByTheInvariantChecker() async {
        let engine = makeEngine(faults: .forgetPoolRelease)
        await engine.start()
        await engine.waitUntilIdle()
        await engine.move(to: 30)
        await engine.waitUntilIdle()
        let problems = await engine.invariantViolations()
        XCTAssertTrue(problems.contains { $0.contains("pool in use") }, "\(problems)")
    }

    /// Guard: failed prepares are suppressed until the next external event.
    /// Check: the bounded wait in `testAlwaysFailingPlayerDoesNotHotLoop`.
    func testMissingFailureSuppressionIsCaught() async {
        let engine = makeEngine(player: SimulatedPlayer(failEvery: 1), faults: .noFailureSuppression)
        await engine.start()
        let settled = await waitUntilIdle(engine, seconds: 1)
        XCTAssertFalse(settled, "the engine retried a failing prepare forever")
        // Stop the loop: with nothing planned there is nothing to retry.
        await engine.setItems([])
        let stopped = await waitUntilIdle(engine, seconds: 5)
        XCTAssertTrue(stopped)
        let snap = await engine.snapshot()
        XCTAssertGreaterThan(snap.stats.preparesStarted, 100)
    }

    /// Guard: the landing clip keeps its in-flight download.
    /// Check: `testLandingOnAClipKeepsItsDownload`.
    func testCancellingTheLandingClipsDownloadIsCaught() async {
        let engine = makeEngine(transport: SimulatedTransport(bytesPerSecond: 10_000_000),
                                faults: .cancelFetchesOnLanding)
        await engine.start()
        await engine.move(to: 1)
        let landed = await engine.snapshot()
        XCTAssertEqual(landed.stats.prefetchesCancelled, 1)
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.rows.first { $0.index == 1 }?.cachedBytes, 0)
    }
}
