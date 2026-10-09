import XCTest
@testable import FeedReadiness

/// Behaviour of the engine with the shipped (fault-free) configuration.
/// `EngineFaultTests` runs the same checks against deliberately broken
/// engines to prove each one can fail.
final class EngineTests: XCTestCase {
    func testSteadyStateHoldsExactlyThePlannedDecodersAndPlays() async {
        let player = SimulatedPlayer()
        let engine = makeEngine(player: player)
        await engine.start()
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.decodersInUse, 3, "playing + 2 ahead (nothing behind item 0)")
        XCTAssertEqual(snap.rows.first { $0.index == 0 }?.decoder, .playing)
        XCTAssertEqual(snap.stats.prefetchesStarted, 5)
        XCTAssertEqual(snap.cacheBytes, 5 * Fixtures.ladder[3].bytes(forSeconds: 6))
        XCTAssertEqual(snap.cacheReservedBytes, 0)
        XCTAssertEqual(snap.stats.bytesFetched, snap.cacheBytes)
        XCTAssertEqual(snap.pending, 0)
        let report = await player.currentReport()
        XCTAssertEqual(report.liveDecoders, 3)
        XCTAssertEqual(report.playing.map(\.key.item), ["v0"])
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    /// The headline property. Twenty swipes land while every prepare takes
    /// 80 ms, so most decoders are still being created when the user leaves
    /// their item. The engine must never let the hardware hold more decoders
    /// than the budget, never release a player mid-creation, leak none, and
    /// end with exactly the landing clip playing.
    func testFlingNeverOvercommitsDecodersOrReleasesMidPrepare() async {
        let player = SimulatedPlayer(prepareLatency: .milliseconds(80))
        let engine = makeEngine(capacity: 4, player: player)
        await engine.start()
        for step in 1 ... 20 { await engine.move(to: step * 2) }
        await engine.waitUntilIdle()

        let report = await player.currentReport()
        XCTAssertLessThanOrEqual(report.maxLiveDecoders, 4)
        XCTAssertEqual(report.releasesDuringPrepare, 0)
        XCTAssertEqual(report.leakedDecoders, 0)
        XCTAssertLessThanOrEqual(report.maxSimultaneouslyPlaying, 1)
        XCTAssertEqual(report.commandsForDeadLeases, 0)
        let snap = await engine.snapshot()
        XCTAssertGreaterThan(snap.stats.deferredReleases, 0, "the fling really did overlap prepares")
        XCTAssertEqual(report.liveDecoders, snap.decodersInUse)
        XCTAssertEqual(snap.rows.first { $0.index == 40 }?.decoder, .playing)
        XCTAssertEqual(report.playing.map(\.key.item), ["v40"])
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    /// Swipe away and straight back while the first window is still
    /// preparing: those decoders must be kept, not torn down and rebuilt.
    func testItemWantedAgainBeforeItsPrepareFinishesIsKept() async {
        let player = SimulatedPlayer(prepareLatency: .milliseconds(80))
        let engine = makeEngine(capacity: 4, player: player)
        await engine.start()          // prepares v0, v1, v2 (3 of 4 slots)
        await engine.move(to: 30)     // v30 takes the last slot; v0-v2 marked for release
        await engine.move(to: 0)      // v0-v2 wanted again before they finished
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.stats.deferredReleases, 1, "only v30 is released")
        XCTAssertEqual(snap.stats.preparesStarted, 4, "v0-v2 were not rebuilt")
        let report = await player.currentReport()
        XCTAssertEqual(report.prepares, 4)
        XCTAssertEqual(report.playing.map(\.key.item), ["v0"])
        XCTAssertEqual(report.liveDecoders, 3)
    }

    /// Swipe away and straight back after the first window is *ready*: its
    /// decoders are mid-release (30 ms each) when they are wanted again.
    /// They must not be handed out again until the port has released them.
    func testItemWantedAgainWhileItsDecoderIsBeingReleasedWaitsForTheRelease() async {
        // Prepares take 50 ms so v30 cannot finish (and re-plan) between
        // the two swipes; releases take 30 ms each so v0-v2 are still being
        // released when they are wanted again.
        let player = SimulatedPlayer(prepareLatency: .milliseconds(50), releaseLatency: .milliseconds(30))
        let engine = makeEngine(capacity: 4, player: player)
        await engine.start()
        await engine.waitUntilIdle()
        await engine.move(to: 30)
        let away = await engine.snapshot()
        await engine.move(to: 0)
        let midway = await engine.snapshot()
        XCTAssertEqual(midway.stats.decoderBusy - away.stats.decoderBusy, 3,
                       "v0-v2 really were wanted again while still releasing")
        await engine.waitUntilIdle()
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
        let snap = await engine.snapshot()
        let report = await player.currentReport()
        XCTAssertEqual(report.liveDecoders, snap.decodersInUse)
        XCTAssertEqual(snap.decodersInUse, 3)
        XCTAssertEqual(report.playing.map(\.key.item), ["v0"])
        XCTAssertEqual(report.releasesDuringPrepare, 0)
        XCTAssertEqual(report.commandsForDeadLeases, 0)
    }

    /// Landing on a clip that cannot play (broken manifest) must still stop
    /// the clip the user left; it stays prepared, just paused.
    func testLeavingAClipPausesItEvenWhenTheNextOneCannotPlay() async {
        var items = Fixtures.feed(6)
        items[1] = FeedItem(id: "broken", renditions: [], durationSeconds: 10)
        let player = SimulatedPlayer()
        let engine = makeEngine(items: items, player: player)
        await engine.start()
        await engine.waitUntilIdle()
        let before = await player.currentReport()
        XCTAssertEqual(before.playing.map(\.key.item), ["v0"])

        await engine.move(to: 1)
        await engine.waitUntilIdle()
        let report = await player.currentReport()
        XCTAssertEqual(report.playing, [], "nothing plays on an unplayable clip")
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.rows.first { $0.index == 0 }?.decoder, .ready, "v0 kept as prepared-behind")
        XCTAssertTrue(snap.diagnostics.contains(.unplayable("broken")))
    }

    /// Random rapid swipe sequences with a slow `pause`: at most one clip
    /// ever plays, no command reaches a released player, and the clip under
    /// the cursor is the one playing at the end.
    func testRapidSwipesNeverPlayTwoClipsOrCommandAReleasedPlayer() async {
        var rng = SplitMix64(seed: 99)
        for _ in 0 ..< 15 {
            let player = SimulatedPlayer(prepareLatency: .milliseconds(5), pauseLatency: .milliseconds(3),
                                         releaseLatency: .milliseconds(2))
            let engine = makeEngine(items: Fixtures.feed(25), player: player)
            await engine.start()
            for _ in 0 ..< 8 {
                await engine.move(to: Int.random(in: 0 ..< 25, using: &rng))
                if Bool.random(using: &rng) { try? await Task.sleep(for: .milliseconds(4)) }
            }
            await engine.waitUntilIdle()
            let report = await player.currentReport()
            let snap = await engine.snapshot()
            XCTAssertLessThanOrEqual(report.maxSimultaneouslyPlaying, 1)
            XCTAssertEqual(report.commandsForDeadLeases, 0)
            XCTAssertEqual(report.releasesDuringPrepare, 0)
            XCTAssertEqual(report.playing.map(\.key.item), [ItemID("v\(snap.cursor ?? -1)")])
            let problems = await engine.invariantViolations()
            XCTAssertEqual(problems, [])
        }
    }

    /// A quality drop re-prepares the clip on screen at the new rendition.
    /// The old decoder must keep playing until the new one is ready. The
    /// replacement's prepare is held at a gate, so "until" is exact.
    func testQualityDowngradeIsMakeBeforeBreak() async {
        let player = SimulatedPlayer()
        let engine = makeEngine(player: player)
        await engine.start()
        await engine.waitUntilIdle()
        await player.holdPrepares()
        await engine.update(conditions: DeviceConditions(throughputKbps: 3_000)) // -> 1.2 Mbps cap
        let gated = await waitUntilPlayer(player, seconds: 3) { $0 >= 1 }
        XCTAssertTrue(gated, "the replacement prepare reached the gate")
        let during = await player.currentReport()
        XCTAssertEqual(during.playing.map(\.key), [DecoderKey(item: "v0", rendition: "1080")],
                       "the old rendition keeps playing while the new one prepares")
        let duringSnap = await engine.snapshot()
        let row0 = duringSnap.rows.first { $0.index == 0 }
        XCTAssertEqual(row0?.rendition, "1080p", "the row shows what is actually playing")
        XCTAssertEqual(row0?.plannedRendition, "540p")
        await player.openPrepares()
        await engine.waitUntilIdle()
        let after = await player.currentReport()
        XCTAssertEqual(after.playing.map(\.key), [DecoderKey(item: "v0", rendition: "540")])
        XCTAssertLessThanOrEqual(after.maxSimultaneouslyPlaying, 1)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.stats.handOffs, 1)
        XCTAssertEqual(snap.rows.first { $0.index == 0 }?.rendition, "540p")
        XCTAssertEqual(after.liveDecoders, snap.decodersInUse)
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    /// The pool is full (playing + three prepared neighbours whose rendition
    /// does not change with the cap). The hand-off must pre-empt a prepared
    /// decoder to make room, then restore it.
    func testHandOffPreemptsAPreparedDecoderWhenThePoolIsFull() async {
        var items = (0 ..< 10).map {
            FeedItem(id: ItemID("v\($0)"), renditions: [Fixtures.ladder[1]], durationSeconds: 20)
        }
        items[2] = Fixtures.feed(3)[2]
        let player = SimulatedPlayer()
        let engine = makeEngine(items: items, capacity: 4, player: player)
        await engine.start()
        await engine.move(to: 2)
        await engine.waitUntilIdle()
        let before = await engine.snapshot()
        XCTAssertEqual(before.decodersInUse, 4, "the pool is full")
        await engine.update(conditions: DeviceConditions(throughputKbps: 3_000))
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        let report = await player.currentReport()
        XCTAssertEqual(report.playing.map(\.key), [DecoderKey(item: "v2", rendition: "540")])
        XCTAssertEqual(snap.stats.preemptions, 1)
        XCTAssertEqual(snap.stats.handOffs, 1)
        XCTAssertEqual(snap.decodersInUse, 4, "the pre-empted neighbour was prepared again")
        XCTAssertEqual(report.liveDecoders, 4)
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    /// With a single decoder there is no room for two: the switch falls back
    /// to break-before-make instead of stalling on the old rendition.
    func testSingleDecoderBudgetFallsBackToBreakBeforeMake() async {
        let player = SimulatedPlayer()
        let engine = makeEngine(capacity: 1, player: player)
        await engine.start()
        await engine.waitUntilIdle()
        await engine.update(conditions: DeviceConditions(thermal: .critical))
        await engine.waitUntilIdle()
        let report = await player.currentReport()
        XCTAssertEqual(report.playing.map(\.key), [DecoderKey(item: "v0", rendition: "360")])
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.stats.breakBeforeMakeFallbacks, 1)
        XCTAssertEqual(snap.decodersInUse, 1)
        XCTAssertEqual(report.maxLiveDecoders, 1)
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    /// Thermal critical drops quality to the floor. Once it clears, quality
    /// climbs back one level per 4 s of sustained headroom; swipes (and
    /// completed downloads) are the check-points.
    func testQualityRecoversAfterThermalPressureClears() async {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        await engine.start()
        await engine.update(conditions: DeviceConditions(thermal: .critical))
        await engine.waitUntilIdle()
        let hot = await engine.snapshot()
        XCTAssertEqual(hot.qualityLevel, 0)
        await engine.update(conditions: .ideal)
        await engine.move(by: 1)
        await engine.waitUntilIdle()
        let early = await engine.snapshot()
        XCTAssertEqual(early.qualityLevel, 0, "no time has passed: no up-switch, however many check-points")
        for expected in 1 ... 3 {
            clock.advance(by: 4.1)
            await engine.move(by: 1)
            await engine.waitUntilIdle()
            let snap = await engine.snapshot()
            XCTAssertEqual(snap.qualityLevel, expected, "one level per dwell")
        }
        let cooled = await engine.snapshot()
        XCTAssertEqual(cooled.stats.qualityUps, 3)
        XCTAssertEqual(cooled.rows.first { $0.index == cooled.cursor }?.rendition, "1080p")
    }

    /// Completed downloads are dwell check-points too: with no swipe and no
    /// condition update after the dwell has elapsed, the next completed
    /// prefetch is what moves quality up.
    func testCompletedDownloadsAreDwellCheckpoints() async {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        await engine.start()
        await engine.update(conditions: DeviceConditions(thermal: .critical))
        await engine.waitUntilIdle()
        await engine.update(conditions: .ideal)
        await engine.waitUntilIdle()
        clock.advance(by: 4.1)
        // New items: no swipe, no update; only their downloads check the dwell.
        await engine.setItems(Fixtures.feed(60).map {
            FeedItem(id: ItemID("next-" + $0.id.raw), renditions: $0.renditions, durationSeconds: 20)
        })
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.qualityLevel, 1)
        XCTAssertEqual(snap.stats.qualityUps, 1)
    }

    /// Throughput oscillating around a level boundary, with a swipe (and
    /// several completed downloads) after every sample. Repeated check-points
    /// must not satisfy the dwell: the engine may step down, never back up.
    func testOscillatingThroughputDoesNotFlapThroughTheEngine() async {
        let clock = ManualClock()
        let player = SimulatedPlayer()
        let engine = makeEngine(player: player, clock: clock)
        await engine.start()
        await engine.waitUntilIdle()
        for sample in 0 ..< 20 {
            clock.advance(by: 1)
            await engine.update(conditions: DeviceConditions(throughputKbps: sample.isMultiple(of: 2) ? 4_800 : 3_600))
            await engine.move(by: 1)
            await engine.waitUntilIdle()
        }
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.stats.qualityUps, 0)
        XCTAssertEqual(snap.stats.qualityDowns, 2, "5 Mbps -> 2.5 Mbps -> 1.2 Mbps, then stable")
        XCTAssertEqual(snap.qualityCapKbps, 1_200)
    }

    /// The user lands on a clip whose prefetch is still downloading: that
    /// download is exactly what the clip needs, so it must not be cancelled.
    func testLandingOnAClipKeepsItsDownload() async {
        let engine = makeEngine(transport: SimulatedTransport(bytesPerSecond: 10_000_000))
        await engine.start()
        await engine.move(to: 1)
        let landed = await engine.snapshot()
        XCTAssertEqual(landed.stats.prefetchesCancelled, 0)
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.rows.first { $0.index == 1 }?.cachedSeconds ?? 0, 6, accuracy: 1e-9)
        XCTAssertEqual(snap.stats.prefetchesFailed, 0)
    }

    /// A fetch is cancelled (its clip leaves the window) and then requested
    /// again (the user swipes back) before the first one's late completion
    /// arrives. That stale completion must not touch the new download.
    /// The transport holds every fetch at a gate, so the order is exact.
    func testStaleFetchCompletionCannotCorruptAReRequest() async {
        let transport = GatedTransport()
        let engine = makeEngine(transport: transport)
        await engine.start()                         // v1-v5 in flight (gated)
        let first = await waitUntilWaiting(transport, count: 5)
        await engine.move(to: 30)                    // cancelled; v31-v35 start
        let second = await waitUntilWaiting(transport, count: 10)
        await engine.move(to: 0)                     // v31-v35 cancelled; v1-v5 requested again
        let third = await waitUntilWaiting(transport, count: 15)
        XCTAssertTrue(first && second && third, "gate order is the order of the three waves")
        await transport.release(first: 10)           // only the 10 cancelled ones complete
        let staleSeen = await waitUntil(engine, seconds: 5) { $0.stats.staleFetchCompletions == 10 }
        XCTAssertTrue(staleSeen)
        await transport.openAll()
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.stats.prefetchesFailed, 0)
        XCTAssertEqual(snap.stats.staleFetchCompletions, 10)
        for index in 1 ... 5 {
            XCTAssertEqual(snap.rows.first { $0.index == index }?.cachedSeconds ?? 0, 6, accuracy: 1e-9)
        }
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    /// The plan's target for a key grows while that key's download is in
    /// flight (cellular 3 s -> Wi-Fi 6 s). When the short download ends, the
    /// engine must fetch the rest before it reports idle.
    func testEngineConvergesWhenATargetGrowsMidDownload() async {
        let transport = GatedTransport()
        let engine = makeEngine(conditions: DeviceConditions(network: .cellular), transport: transport)
        await engine.start()                         // v1-v3, 3 s each (gated)
        await engine.update(conditions: .ideal)      // plan now wants 6 s for v1-v5
        await transport.openAll()
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        for index in 1 ... 5 {
            XCTAssertEqual(snap.rows.first { $0.index == index }?.cachedSeconds ?? 0, 6, accuracy: 1e-9,
                           "clip \(index)")
        }
    }

    func testAlwaysFailingPlayerDoesNotHotLoop() async {
        let player = SimulatedPlayer(failEvery: 1)
        let engine = makeEngine(player: player)
        await engine.start()
        // Bounded wait: without failure suppression the engine would retry
        // forever and `waitUntilIdle` would never return.
        let settled = await waitUntilIdle(engine, seconds: 3)
        XCTAssertTrue(settled, "engine kept retrying a failing prepare")
        guard settled else { return }
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.stats.preparesStarted, 3, "one attempt per planned decoder, no retries")
        XCTAssertEqual(snap.stats.preparesFailed, 3)
        XCTAssertEqual(snap.decodersInUse, 0)
        // A failed prepare is still released through the port: no hardware leak.
        let report = await player.currentReport()
        XCTAssertEqual(report.releases, 3)
        XCTAssertEqual(report.liveDecoders, 0)
        // The next real event retries.
        await engine.move(to: 0)
        await engine.waitUntilIdle()
        let retried = await engine.snapshot()
        XCTAssertEqual(retried.stats.preparesStarted, 6)
    }

    /// Failure injection counts by call order even when calls overlap.
    func testSimulatedFailureInjectionIsExactUnderConcurrency() async {
        let prepares = makeEngine(player: SimulatedPlayer(prepareLatency: .milliseconds(20), failEvery: 2))
        await prepares.start()
        await prepares.waitUntilIdle()
        let preparesSnap = await prepares.snapshot()
        XCTAssertEqual(preparesSnap.stats.preparesFailed, 1, "3 overlapping prepares, the 2nd fails")

        let fetches = makeEngine(transport: SimulatedTransport(bytesPerSecond: 50_000_000, failEvery: 2))
        await fetches.start()
        await fetches.waitUntilIdle()
        let fetchesSnap = await fetches.snapshot()
        XCTAssertEqual(fetchesSnap.stats.prefetchesFailed, 2, "5 overlapping fetches, the 2nd and 4th fail")
    }

    func testGoingOfflineCancelsInFlightFetchesButKeepsPreparedClipsPlaying() async {
        let player = SimulatedPlayer()
        let engine = makeEngine(player: player, transport: SimulatedTransport(bytesPerSecond: 1_000))
        await engine.start()
        let ready = await waitUntil(engine, seconds: 3) { snap in
            snap.rows.first { $0.index == 0 }?.decoder == .playing
                && snap.rows.filter { $0.index <= 2 }.allSatisfy { $0.decoder == .playing || $0.decoder == .ready }
        }
        XCTAssertTrue(ready, "v0 playing, v1 and v2 prepared")
        let before = await engine.snapshot()
        XCTAssertGreaterThan(before.cacheReservedBytes, 0, "space is reserved before bytes arrive")
        XCTAssertEqual(before.cacheBytes, 0)
        XCTAssertEqual(before.rows.first { $0.index == 3 }?.cachedBytes, 0, "rows count delivered bytes, not reservations")

        await engine.update(conditions: DeviceConditions(network: .offline))
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.stats.prefetchesCancelled, 5)
        XCTAssertEqual(snap.stats.bytesCancelled, before.cacheReservedBytes)
        XCTAssertEqual(snap.cacheReservedBytes, 0)
        XCTAssertEqual(snap.cacheBytes, 0)
        await engine.waitUntilIdle()
        let settled = await engine.snapshot()
        XCTAssertEqual(settled.stats.staleFetchCompletions, 5, "late completions were recognised and ignored")
        XCTAssertEqual(settled.cacheBytes, 0)
        // Nothing is cached, but v0 and v1 already have prepared players:
        // offline they keep playing / stay ready. v2 is released.
        XCTAssertEqual(settled.decodersInUse, 2)
        let report = await player.currentReport()
        XCTAssertEqual(report.playing.map(\.key.item), ["v0"])
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    func testFailedFetchShrinksItsReservation() async {
        let engine = makeEngine(transport: SimulatedTransport(failEvery: 1))
        await engine.start()
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        // Every attempt fails; a failed clip is retried on later re-plans
        // (prepare completions), so count attempts rather than assume five.
        XCTAssertGreaterThanOrEqual(snap.stats.prefetchesFailed, 5)
        XCTAssertEqual(snap.stats.prefetchesFailed, snap.stats.prefetchesStarted)
        XCTAssertEqual(snap.cacheBytes, 0)
        XCTAssertEqual(snap.cacheReservedBytes, 0)
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    func testThermalCriticalShedsDecodersAndDropsQuality() async {
        let player = SimulatedPlayer()
        let engine = makeEngine(capacity: 4, player: player)
        await engine.start()
        await engine.move(to: 5)
        await engine.waitUntilIdle()
        let before = await engine.snapshot()
        XCTAssertEqual(before.decodersInUse, 4)
        XCTAssertEqual(before.qualityCapKbps, 5_000)
        XCTAssertEqual(before.rows.first { $0.index == 7 }?.cachedSeconds ?? 0, 6, accuracy: 1e-9)

        await engine.update(conditions: DeviceConditions(thermal: .critical))
        await engine.waitUntilIdle()
        let hot = await engine.snapshot()
        XCTAssertEqual(hot.decodersInUse, 1, "only the playing item keeps a decoder")
        XCTAssertEqual(hot.qualityCapKbps, 600)
        XCTAssertEqual(hot.stats.handOffs, 1, "the clip on screen switched rendition make-before-break")
        XCTAssertEqual(hot.rows.first { $0.index == 5 }?.rendition, "360p", "re-prepared at the capped rendition")
        XCTAssertEqual(hot.rows.first { $0.index == 5 }?.decoder, .playing)
        // Item 6 was re-fetched at 360p; item 7 still has 6 s of *1080p* on
        // disk, which is useless to a 360p decoder, so its row reports 0.
        XCTAssertEqual(hot.rows.first { $0.index == 6 }?.cachedSeconds ?? 0, 6, accuracy: 1e-9)
        XCTAssertEqual(hot.rows.first { $0.index == 7 }?.cachedBytes, 0)
        XCTAssertEqual(hot.shape.prefetchAhead, 1)
        let report = await player.currentReport()
        XCTAssertEqual(report.liveDecoders, 1)
        XCTAssertEqual(report.playing.map(\.key), [DecoderKey(item: "v5", rendition: "360")])
    }

    func testTinyCacheBudgetRefusesInsteadOfOvercommitting() async {
        let engine = makeEngine(budget: 1_000)
        await engine.start()
        await engine.waitUntilIdle()
        let snap = await engine.snapshot()
        XCTAssertGreaterThanOrEqual(snap.stats.cacheRefusals, 5, "every clip's request was refused")
        XCTAssertEqual(snap.stats.prefetchesStarted, 0)
        XCTAssertLessThanOrEqual(snap.cacheBytes + snap.cacheReservedBytes, 1_000)
        let problems = await engine.invariantViolations()
        XCTAssertEqual(problems, [])
    }

    func testSkipperGetsShallowerPrefetchThanWatcher() async {
        func bytesAfterTraining(watch: Double, velocity: Double) async -> Int64 {
            let engine = makeEngine()
            await engine.start()
            for step in 1 ... 15 {
                await engine.move(to: step, leaving: .init(watchFraction: watch, swipeVelocity: velocity))
            }
            await engine.waitUntilIdle()
            await engine.setItems(Fixtures.feed(60).map {
                FeedItem(id: ItemID("fresh-" + $0.id.raw), renditions: $0.renditions, durationSeconds: 20)
            })
            await engine.waitUntilIdle()
            let snap = await engine.snapshot()
            return snap.rows.filter { $0.index > snap.cursor ?? 0 }.map(\.cachedBytes).reduce(0, +)
        }
        let skipper = await bytesAfterTraining(watch: 0.05, velocity: 2_500)
        let watcher = await bytesAfterTraining(watch: 0.95, velocity: 300)
        XCTAssertGreaterThan(watcher, 0)
        XCTAssertLessThan(skipper * 3, watcher, "first-segment-only prefetch is 1.5 s vs 6 s")
    }

    /// Swiping past the end of the feed leaves no clip, so it must not
    /// teach the skip model anything.
    func testSwipingPastTheEndDoesNotTrainTheSkipModel() async {
        let engine = makeEngine(items: Fixtures.feed(3))
        await engine.start()
        await engine.move(to: 2)
        let before = await engine.snapshot()
        for _ in 0 ..< 10 {
            await engine.move(by: 1, leaving: .init(watchFraction: 0.01, swipeVelocity: 3_000))
        }
        await engine.waitUntilIdle()
        let after = await engine.snapshot()
        XCTAssertEqual(after.cursor, 2)
        XCTAssertEqual(after.skipProbability, before.skipProbability, accuracy: 1e-12)
    }

    func testMoveByUsesTheEnginesOwnCursor() async {
        let engine = makeEngine()
        await engine.start()
        async let first: Void = engine.move(by: 1)
        async let second: Void = engine.move(by: 1)
        _ = await (first, second)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.cursor, 2, "two quick swipes are two swipes")
        await engine.waitUntilIdle()
    }

    func testEmptyFeedOutOfRangeMovesAndHostileNumbersAreSafe() async {
        let engine = makeEngine(items: [])
        await engine.start()
        await engine.move(to: 50)
        await engine.move(to: -50)
        await engine.move(by: .max)
        await engine.waitUntilIdle()
        let snap = await engine.snapshot(behind: .max, ahead: .min)
        XCTAssertEqual(snap.rows, [])
        XCTAssertEqual(snap.diagnostics, [.emptyFeed])
        await engine.setItems(Fixtures.feed(3))
        await engine.move(to: Int.max)
        await engine.move(by: .max)
        await engine.move(by: .min)
        await engine.move(by: .max)
        await engine.waitUntilIdle()
        let after = await engine.snapshot(behind: .max, ahead: .max)
        XCTAssertEqual(after.cursor, 2)
        XCTAssertEqual(after.rows.map(\.index), [0, 1, 2])

        let hostile = FeedEngine(items: Fixtures.feed(5),
                                 configuration: .init(decoderCapacity: .max, cacheBudgetBytes: .max,
                                                      startLevel: .max, skipThreshold: .nan),
                                 player: SimulatedPlayer(), transport: SimulatedTransport())
        await hostile.start()
        await hostile.waitUntilIdle()
        let hostileSnap = await hostile.snapshot()
        XCTAssertEqual(hostileSnap.decoderCapacity, DecoderPool.maximumCapacity)
        XCTAssertEqual(hostileSnap.skipThreshold, 0.7)
        let problems = await hostile.invariantViolations()
        XCTAssertEqual(problems, [])
    }
}

// MARK: - Shared helpers

extension XCTestCase {
    func makeEngine(items: [FeedItem] = Fixtures.feed(60),
                    conditions: DeviceConditions = .ideal,
                    capacity: Int = 4,
                    budget: Int64 = 64 * 1_024 * 1_024,
                    player: SimulatedPlayer = SimulatedPlayer(),
                    transport: any PrefetchTransport = SimulatedTransport(),
                    clock: any FeedClock = ManualClock(),
                    faults: FeedEngine.FaultInjection = []) -> FeedEngine {
        FeedEngine(items: items, conditions: conditions,
                   configuration: .init(decoderCapacity: capacity, cacheBudgetBytes: budget, startLevel: 3),
                   player: player, transport: transport, policy: DefaultWindowPolicy(),
                   predictor: SkipPredictor(), clock: clock, faults: faults)
    }

    /// `waitUntilIdle` with a deadline, for engines that may never settle.
    func waitUntilIdle(_ engine: FeedEngine, seconds: Double) async -> Bool {
        let flag = Flag()
        Task {
            await engine.waitUntilIdle()
            await flag.set()
        }
        for _ in 0 ..< Int(seconds * 100) {
            if await flag.isSet { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await flag.isSet
    }

    /// Polls the gated transport until `count` fetches wait at its gate.
    func waitUntilWaiting(_ transport: GatedTransport, count: Int, seconds: Double = 5) async -> Bool {
        for _ in 0 ..< Int(seconds * 100) {
            if await transport.waiting >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Polls the player until the number of prepares at its gate satisfies `condition`.
    func waitUntilPlayer(_ player: SimulatedPlayer, seconds: Double,
                         _ condition: @Sendable (Int) -> Bool) async -> Bool {
        for _ in 0 ..< Int(seconds * 100) {
            if condition(await player.preparesAtGate) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Polls snapshots until `condition` holds or the deadline passes.
    func waitUntil(_ engine: FeedEngine, seconds: Double,
                   _ condition: @Sendable (FeedEngine.Snapshot) -> Bool) async -> Bool {
        for _ in 0 ..< Int(seconds * 100) {
            if condition(await engine.snapshot()) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

actor Flag {
    var isSet = false
    func set() { isSet = true }
}
