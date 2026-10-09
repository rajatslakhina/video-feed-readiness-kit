import XCTest
@testable import FeedReadiness

final class ArithmeticTests: XCTestCase {
    func testSaturatingAddSubtractMultiplyClampInsteadOfTrapping() {
        XCTAssertEqual(Saturating.add(.max, 1), .max)
        XCTAssertEqual(Saturating.add(.min, -1), .min)
        XCTAssertEqual(Saturating.subtract(.min, 1), .min)
        XCTAssertEqual(Saturating.subtract(.max, -1), .max)
        XCTAssertEqual(Saturating.multiply(.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(.max, -2), .min)
        XCTAssertEqual(Saturating.multiply(.min, -1), .max)
        XCTAssertEqual(Saturating.add(40, 2), 42)
        XCTAssertEqual(Saturating.multiply(6, 7), 42)
    }

    func testDoubleToInt64HandlesNaNInfinityAndTheTwoToThe63Boundary() {
        XCTAssertEqual(Saturating.nonNegativeInt64(.nan), 0)
        XCTAssertEqual(Saturating.nonNegativeInt64(-.infinity), 0)
        XCTAssertEqual(Saturating.nonNegativeInt64(.infinity), .max)
        XCTAssertEqual(Saturating.nonNegativeInt64(-5), 0)
        // Double(Int64.max) is exactly 2^63, one past the largest Int64.
        XCTAssertEqual(Saturating.nonNegativeInt64(Double(Int64.max)), .max)
        XCTAssertEqual(Saturating.nonNegativeInt64(9.3e18), .max)
        XCTAssertEqual(Saturating.nonNegativeInt64(1_234.9), 1_234)
    }

    func testIndexHelperRejectsOverflowAndOutOfRange() {
        XCTAssertNil(Saturating.index(Int.max, offset: 1, count: 10))
        XCTAssertNil(Saturating.index(0, offset: -1, count: 10))
        XCTAssertNil(Saturating.index(9, offset: 1, count: 10))
        XCTAssertNil(Saturating.index(0, offset: 0, count: 0))
        XCTAssertEqual(Saturating.index(3, offset: 2, count: 10), 5)
    }

    func testIncrementSticksAtMax() {
        var value = Int.max
        Saturating.increment(&value)
        XCTAssertEqual(value, .max)
    }
}

final class ModelTests: XCTestCase {
    func testRenditionByteMathNeverTraps() {
        let huge = Rendition(id: "x", height: 1, bitrateKbps: .max)
        XCTAssertEqual(huge.bytesPerSecond, .max)
        XCTAssertEqual(huge.bytes(forSeconds: 10), .max)
        let normal = Rendition(id: "a", height: 720, bitrateKbps: 2_500)
        XCTAssertEqual(normal.bytesPerSecond, 312_500)
        XCTAssertEqual(normal.bytes(forSeconds: 2), 625_000)
        XCTAssertEqual(normal.bytes(forSeconds: .nan), 0)
        XCTAssertEqual(normal.bytes(forSeconds: -3), 0)
        XCTAssertEqual(Rendition(id: "n", height: -1, bitrateKbps: -100).bytesPerSecond, 0)
    }

    func testFeedItemNormalisesRenditions() {
        let item = FeedItem(id: "a", renditions: [
            Rendition(id: "hi", height: 1_080, bitrateKbps: 5_000),
            Rendition(id: "zero", height: 1, bitrateKbps: 0),
            Rendition(id: "lo", height: 360, bitrateKbps: 600),
            Rendition(id: "hi", height: 1_080, bitrateKbps: 9_999), // duplicate id dropped
        ], durationSeconds: .infinity)
        XCTAssertEqual(item.renditions.map(\.id), ["lo", "hi"])
        XCTAssertEqual(item.durationSeconds, 0)
    }

    func testCappedRenditionDegradesButNeverRefuses() {
        let item = Fixtures.feed(1)[0]
        XCTAssertEqual(item.rendition(cappedAt: 2_500)?.id, "720")
        XCTAssertEqual(item.rendition(cappedAt: 2_499)?.id, "540")
        XCTAssertEqual(item.rendition(cappedAt: 10)?.id, "360", "below every rendition: lowest, not nil")
        XCTAssertNil(FeedItem(id: "dead", renditions: [], durationSeconds: 5).rendition(cappedAt: 5_000))
    }

    func testConditionsPartialOrder() {
        let good = DeviceConditions.ideal
        let bad = DeviceConditions(network: .cellular, lowPowerMode: true, thermal: .serious, memory: .warning)
        XCTAssertTrue(bad.isNoBetter(than: good))
        XCTAssertFalse(good.isNoBetter(than: bad))
        // Incomparable: better network, worse thermal.
        let mixed = DeviceConditions(network: .wifi, thermal: .critical)
        XCTAssertFalse(mixed.isNoBetter(than: bad))
        XCTAssertFalse(bad.isNoBetter(than: mixed))
    }
}
