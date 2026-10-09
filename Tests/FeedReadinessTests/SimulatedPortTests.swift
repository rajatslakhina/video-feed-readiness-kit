import XCTest
@testable import FeedReadiness

/// The contract checks in `SimulatedPlayer` are what the engine tests trust
/// (`== 0` assertions on them). These tests drive the player directly with
/// contract violations and assert each counter really counts.
final class SimulatedPortTests: XCTestCase {
    private func lease(_ item: String, _ generation: UInt64 = 1) -> DecoderLease {
        DecoderLease(key: DecoderKey(item: ItemID(item), rendition: "720"), slot: 0, generation: generation)
    }

    private let item = FeedItem(id: "a", renditions: [Rendition(id: "720", height: 720, bitrateKbps: 2_500)],
                                durationSeconds: 10)

    func testCommandsToDeadOrFailedLeasesAreCounted() async throws {
        let player = SimulatedPlayer(failEvery: 2)
        await player.play(lease("never-prepared"))
        var report = await player.currentReport()
        XCTAssertEqual(report.commandsForDeadLeases, 1, "play before prepare")

        let ok = lease("ok")
        try await player.prepare(item, rendition: item.renditions[0], lease: ok)
        await player.play(ok)
        report = await player.currentReport()
        XCTAssertEqual(report.playing, [ok])
        await player.release(ok)
        await player.pause(ok)
        await player.play(ok)
        report = await player.currentReport()
        XCTAssertEqual(report.commandsForDeadLeases, 3, "pause and play after release")
        XCTAssertEqual(report.playing, [])

        let bad = lease("bad")
        do {
            try await player.prepare(item, rendition: item.renditions[0], lease: bad) // 2nd prepare fails
            XCTFail("expected an injected failure")
        } catch {}
        await player.play(bad)
        report = await player.currentReport()
        XCTAssertEqual(report.commandsForDeadLeases, 4, "play for a lease whose prepare failed")
    }

    func testReleaseDuringPrepareLeaksAndIsCounted() async throws {
        let player = SimulatedPlayer()
        await player.holdPrepares()
        let held = lease("held")
        let item = self.item
        let prepare = Task { try await player.prepare(item, rendition: item.renditions[0], lease: held) }
        while await player.preparesAtGate < 1 { try await Task.sleep(for: .milliseconds(5)) }
        await player.release(held)
        await player.openPrepares()
        try await prepare.value
        let report = await player.currentReport()
        XCTAssertEqual(report.releasesDuringPrepare, 1)
        XCTAssertEqual(report.leakedDecoders, 1)
        XCTAssertEqual(report.liveDecoders, 1, "the leaked decoder is still allocated")
    }

    func testSimultaneousPlaybackAndLiveDecodersAreCounted() async throws {
        let player = SimulatedPlayer()
        let first = lease("first", 1)
        let second = lease("second", 2)
        try await player.prepare(item, rendition: item.renditions[0], lease: first)
        try await player.prepare(item, rendition: item.renditions[0], lease: second)
        await player.play(first)
        await player.play(second)
        let report = await player.currentReport()
        XCTAssertEqual(report.maxSimultaneouslyPlaying, 2)
        XCTAssertEqual(report.maxLiveDecoders, 2)
    }
}
