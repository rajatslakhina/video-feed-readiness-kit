/// Byte-budgeted disk cache bookkeeping for prefetched media, keyed by
/// (item, rendition).
///
/// Policy: least-recently-used eviction, except that *pinned* keys (the
/// exact (item, rendition) pairs the current readiness window will use) are
/// never evicted. Pinning is per rendition on purpose: after a quality
/// downgrade, the old rendition's bytes of a window item are useless to the
/// new decoder and should be the first thing to go, not protected.
/// Space is reserved *before* a download starts, so the budget holds even
/// while fetches are in flight; a failed or cancelled fetch shrinks its
/// reservation back.
///
/// This type tracks bytes, not files. The app's storage layer applies the
/// returned evictions; keeping the policy pure is what makes it testable.
public struct RenditionCache: Sendable, Equatable {
    public enum CacheError: Error, Equatable, Sendable {
        /// The request alone is larger than the whole budget.
        case exceedsBudget(requested: Int64, budget: Int64)
        /// Enough space exists only by evicting pinned entries. Nothing was evicted.
        case pinnedBytesExhaustBudget(needed: Int64, evictable: Int64)
    }

    struct Entry: Sendable, Equatable {
        var bytes: Int64
        var lastUse: UInt64
    }

    public let budgetBytes: Int64
    private(set) var entries: [CacheKey: Entry] = [:]
    public private(set) var pinnedKeys: Set<CacheKey> = []
    public private(set) var totalBytes: Int64 = 0
    private var clock: UInt64 = 0

    public init(budgetBytes: Int64) {
        self.budgetBytes = max(0, budgetBytes)
    }

    public var keys: [CacheKey] { entries.keys.sorted() }
    public func bytes(for key: CacheKey) -> Int64 { entries[key]?.bytes ?? 0 }

    public mutating func setPinned(_ keys: Set<CacheKey>) {
        pinnedKeys = keys
    }

    private mutating func tick() -> UInt64 {
        clock &+= 1
        return clock
    }

    public mutating func touch(_ key: CacheKey) {
        guard entries[key] != nil else { return }
        let stamp = tick()
        entries[key]?.lastUse = stamp
    }

    /// Grows `key` to `targetBytes` total, evicting unpinned LRU entries if
    /// needed. Atomic: on failure no entry is changed or evicted.
    /// A target at or below the current size is a no-op success.
    /// Returns the evicted keys, oldest first.
    public mutating func reserve(_ key: CacheKey, totalBytes targetBytes: Int64) -> Result<[CacheKey], CacheError> {
        let target = max(0, targetBytes)
        let current = bytes(for: key)
        guard target > current else {
            touch(key)
            return .success([])
        }
        guard target <= budgetBytes else {
            return .failure(.exceedsBudget(requested: target, budget: budgetBytes))
        }
        let growth = Saturating.subtract(target, current)
        let free = Saturating.subtract(budgetBytes, totalBytes)
        var needed = Saturating.subtract(growth, free)

        // Plan evictions first, commit only if they suffice.
        var victims: [CacheKey] = []
        if needed > 0 {
            let candidates = entries
                .filter { $0.key != key && !pinnedKeys.contains($0.key) }
                .sorted { ($0.value.lastUse, $0.key) < ($1.value.lastUse, $1.key) }
            var reclaimable: Int64 = 0
            for (candidateKey, entry) in candidates where needed > 0 {
                victims.append(candidateKey)
                reclaimable = Saturating.add(reclaimable, entry.bytes)
                needed = Saturating.subtract(needed, entry.bytes)
            }
            guard needed <= 0 else {
                return .failure(.pinnedBytesExhaustBudget(needed: Saturating.subtract(growth, free),
                                                         evictable: reclaimable))
            }
        }
        for victim in victims { _ = remove(victim) }
        let stamp = tick()
        entries[key] = Entry(bytes: target, lastUse: stamp)
        totalBytes = Saturating.add(totalBytes, growth)
        return .success(victims)
    }

    /// Shrinks `key` to at most `bytes` (used when a fetch fails or is
    /// cancelled). Removes the entry when it reaches 0. Never grows.
    public mutating func shrink(_ key: CacheKey, to bytes: Int64) {
        guard let entry = entries[key] else { return }
        let newSize = max(0, min(bytes, entry.bytes))
        totalBytes = Saturating.subtract(totalBytes, Saturating.subtract(entry.bytes, newSize))
        if newSize == 0 {
            entries[key] = nil
        } else {
            entries[key]?.bytes = newSize
        }
    }

    /// Removes `key`, returning the bytes freed.
    @discardableResult
    public mutating func remove(_ key: CacheKey) -> Int64 {
        guard let entry = entries.removeValue(forKey: key) else { return 0 }
        totalBytes = Saturating.subtract(totalBytes, entry.bytes)
        return entry.bytes
    }

    public var invariantViolations: [String] {
        var problems: [String] = []
        let sum = entries.values.reduce(Int64(0)) { Saturating.add($0, $1.bytes) }
        if sum != totalBytes { problems.append("tracked total \(totalBytes) != sum of entries \(sum)") }
        if totalBytes > budgetBytes { problems.append("total \(totalBytes) exceeds budget \(budgetBytes)") }
        if entries.values.contains(where: { $0.bytes <= 0 }) { problems.append("empty entry retained") }
        return problems
    }
}
