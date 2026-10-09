import XCTest
@testable import FeedReadiness

final class DecoderPoolTests: XCTestCase {
    private func key(_ i: Int) -> DecoderKey { DecoderKey(item: ItemID("v\(i)"), rendition: "720") }

    func testCapacityIsEnforcedAndAcquireIsIdempotent() throws {
        var pool = DecoderPool(capacity: 2)
        let first = try pool.acquire(key(0)).get()
        XCTAssertEqual(try pool.acquire(key(0)).get(), first, "same key, same lease")
        _ = try pool.acquire(key(1)).get()
        XCTAssertEqual(pool.acquire(key(2)), .failure(.exhausted))
        XCTAssertEqual(pool.inUse, 2)
        XCTAssertEqual(pool.invariantViolations, [])
    }

    /// The generation is what makes a late release harmless: after slot 0 is
    /// reused, releasing the *old* lease must not free the new holder.
    func testStaleReleaseCannotFreeASlotThatWasReassigned() throws {
        var pool = DecoderPool(capacity: 1)
        let old = try pool.acquire(key(0)).get()
        XCTAssertTrue(pool.release(old))
        let new = try pool.acquire(key(0)).get()
        XCTAssertEqual(new.slot, old.slot)
        XCTAssertNotEqual(new.generation, old.generation)
        XCTAssertFalse(pool.release(old), "stale lease must be rejected")
        XCTAssertTrue(pool.isCurrent(new))
        XCTAssertEqual(pool.inUse, 1)
        XCTAssertFalse(pool.release(DecoderLease(key: key(9), slot: 42, generation: 1)), "unknown slot")
    }

    func testZeroAndNegativeCapacity() {
        var none = DecoderPool(capacity: -3)
        XCTAssertEqual(none.capacity, 0)
        XCTAssertEqual(none.acquire(key(0)), .failure(.exhausted))
    }
}

final class RenditionCacheTests: XCTestCase {
    private func key(_ i: Int, _ r: String = "720") -> CacheKey { CacheKey(item: ItemID("v\(i)"), rendition: r) }

    func testEvictsLeastRecentlyUsedFirstAndReportsVictimsInOrder() throws {
        var cache = RenditionCache(budgetBytes: 300)
        _ = try cache.reserve(key(1), totalBytes: 100).get()
        _ = try cache.reserve(key(2), totalBytes: 100).get()
        _ = try cache.reserve(key(3), totalBytes: 100).get()
        cache.touch(key(1)) // 2 is now the oldest, then 3
        let evicted = try cache.reserve(key(4), totalBytes: 150).get()
        XCTAssertEqual(evicted, [key(2), key(3)])
        XCTAssertEqual(cache.keys, [key(1), key(4)])
        XCTAssertEqual(cache.totalBytes, 250)
        XCTAssertEqual(cache.invariantViolations, [])
    }

    func testPinnedEntriesAreNeverEvicted() throws {
        var cache = RenditionCache(budgetBytes: 300)
        _ = try cache.reserve(key(1), totalBytes: 100).get()
        _ = try cache.reserve(key(2), totalBytes: 100).get()
        _ = try cache.reserve(key(3), totalBytes: 100).get()
        cache.setPinned([key(1)])
        let evicted = try cache.reserve(key(4), totalBytes: 100).get()
        XCTAssertEqual(evicted, [key(2)], "v1 is older but pinned")
    }

    /// Pinning is per rendition: after a downgrade the window pins the new
    /// rendition, and the old rendition's bytes of the same item are the
    /// first to go.
    func testPinningIsPerRenditionSoStaleRenditionsAreEvictable() throws {
        var cache = RenditionCache(budgetBytes: 300)
        _ = try cache.reserve(key(1, "1080"), totalBytes: 100).get() // oldest
        _ = try cache.reserve(key(2), totalBytes: 100).get()
        _ = try cache.reserve(key(1, "360"), totalBytes: 100).get()
        cache.setPinned([key(1, "360"), key(2)])
        let evicted = try cache.reserve(key(3), totalBytes: 100).get()
        XCTAssertEqual(evicted, [key(1, "1080")])
    }

    func testDecoderPoolCapacityIsBounded() {
        XCTAssertEqual(DecoderPool(capacity: .max).capacity, DecoderPool.maximumCapacity)
        XCTAssertEqual(DecoderPool(capacity: .min).capacity, 0)
    }

    func testFailureIsAtomicNothingEvicted() throws {
        var cache = RenditionCache(budgetBytes: 300)
        _ = try cache.reserve(key(1), totalBytes: 100).get()
        _ = try cache.reserve(key(2), totalBytes: 150).get()
        cache.setPinned([key(2)])
        let before = cache
        XCTAssertEqual(cache.reserve(key(3), totalBytes: 250),
                       .failure(.pinnedBytesExhaustBudget(needed: 200, evictable: 100)))
        XCTAssertEqual(cache, before, "a refused reservation must not evict the unpinned entry")
        XCTAssertEqual(cache.reserve(key(5), totalBytes: 301), .failure(.exceedsBudget(requested: 301, budget: 300)))
    }

    func testGrowingAnEntryOnlyChargesTheGrowthAndShrinkRestores() throws {
        var cache = RenditionCache(budgetBytes: 1_000)
        _ = try cache.reserve(key(1), totalBytes: 100).get()
        _ = try cache.reserve(key(1), totalBytes: 400).get()
        XCTAssertEqual(cache.totalBytes, 400)
        XCTAssertEqual(try cache.reserve(key(1), totalBytes: 50).get(), [], "never shrinks via reserve")
        XCTAssertEqual(cache.bytes(for: key(1)), 400)
        cache.shrink(key(1), to: 100)
        XCTAssertEqual(cache.totalBytes, 100)
        cache.shrink(key(1), to: 900)
        XCTAssertEqual(cache.bytes(for: key(1)), 100, "shrink never grows")
        cache.shrink(key(1), to: 0)
        XCTAssertEqual(cache.keys, [])
        XCTAssertEqual(cache.totalBytes, 0)
        cache.shrink(key(7), to: 0) // unknown key: no-op
        XCTAssertEqual(cache.invariantViolations, [])
    }

    /// Random reserve/shrink/remove/pin traffic against a simple reference
    /// model of the same rules. Checks the budget invariant *and* that the
    /// set of entries matches the model, so a cache that "stays under budget"
    /// by silently dropping entries would still fail.
    func testRandomTrafficMatchesAReferenceModel() {
        var rng = SplitMix64(seed: 7)
        var cache = RenditionCache(budgetBytes: 2_000)
        var model: [CacheKey: (bytes: Int64, use: Int)] = [:]
        var pinned = Set<CacheKey>()
        var clock = 0
        for _ in 0 ..< 3_000 {
            let k = key(Int.random(in: 0 ..< 12, using: &rng), ["360", "720"].randomElement(using: &rng) ?? "360")
            switch Int.random(in: 0 ..< 10, using: &rng) {
            case 0 ..< 6:
                let target = Int64.random(in: 0 ... 900, using: &rng)
                let result = cache.reserve(k, totalBytes: target)
                // Reference model of the same policy.
                let current = model[k]?.bytes ?? 0
                if target <= current {
                    if model[k] != nil { clock += 1; model[k]?.use = clock }
                    XCTAssertEqual(try? result.get(), [])
                } else {
                    let total = model.values.reduce(Int64(0)) { $0 + $1.bytes }
                    var needed = (target - current) - (2_000 - total)
                    let candidates = model.filter { $0.key != k && !pinned.contains($0.key) }
                        .sorted { ($0.value.use, $0.key) < ($1.value.use, $1.key) }
                    var victims: [CacheKey] = []
                    for (ck, entry) in candidates where needed > 0 {
                        victims.append(ck); needed -= entry.bytes
                    }
                    if needed > 0 {
                        XCTAssertNil(try? result.get())
                    } else {
                        XCTAssertEqual(try? result.get(), victims)
                        for v in victims { model[v] = nil }
                        clock += 1
                        model[k] = (target, clock)
                    }
                }
            case 6:
                cache.touch(k)
                if model[k] != nil { clock += 1; model[k]?.use = clock }
            case 7:
                let to = Int64.random(in: 0 ... 500, using: &rng)
                cache.shrink(k, to: to)
                if let entry = model[k] {
                    let size = min(to, entry.bytes)
                    model[k] = size == 0 ? nil : (size, entry.use)
                }
            case 8:
                cache.remove(k)
                model[k] = nil
            default:
                pinned = Set((0 ..< 4).map { _ in
                    key(Int.random(in: 0 ..< 12, using: &rng), ["360", "720"].randomElement(using: &rng) ?? "360")
                })
                cache.setPinned(pinned)
            }
            XCTAssertEqual(cache.invariantViolations, [])
            XCTAssertEqual(Set(cache.keys), Set(model.keys))
        }
    }
}
