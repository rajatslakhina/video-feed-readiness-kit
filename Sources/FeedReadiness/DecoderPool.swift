/// What a decoder is holding: one rendition of one item. Keyed by rendition
/// because a quality switch briefly needs a second decoder for the same item.
public struct DecoderKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let item: ItemID
    public let rendition: String
    public init(item: ItemID, rendition: String) {
        self.item = item
        self.rendition = rendition
    }
    public var description: String { "\(item.raw)@\(rendition)" }
    public static func < (l: Self, r: Self) -> Bool { (l.item.raw, l.rendition) < (r.item.raw, r.rendition) }
}

/// Proof of holding one decoder slot. The generation makes every lease
/// unique for the life of the pool, so a late `release` of an old lease can
/// never free a slot that has since been handed to someone else.
public struct DecoderLease: Hashable, Sendable, CustomStringConvertible {
    public let key: DecoderKey
    public let slot: Int
    public let generation: UInt64
    public var description: String { "\(key)#\(generation)" }
}

/// A fixed number of hardware decoder slots.
///
/// iOS does not publish a decoder limit, and exceeding it surfaces as
/// AVPlayerItem failures or silent black frames, not a clean error. So the
/// app owns an explicit budget and never asks for more than it.
public struct DecoderPool: Sendable, Equatable {
    public enum PoolError: Error, Equatable, Sendable { case exhausted }

    /// Upper bound on `capacity`. Phones have a handful of hardware decoder
    /// sessions; the bound keeps the slot table small and stops a hostile
    /// configuration (`capacity: .max`) from trying to allocate it.
    public static let maximumCapacity = 64

    public let capacity: Int
    private var slots: [DecoderLease?]
    private var byKey: [DecoderKey: DecoderLease] = [:]
    private var nextGeneration: UInt64 = 1

    public init(capacity: Int) {
        let bounded = min(max(0, capacity), Self.maximumCapacity)
        self.capacity = bounded
        self.slots = Array(repeating: nil, count: bounded)
    }

    public var inUse: Int { byKey.count }
    public var leases: [DecoderLease] { byKey.values.sorted { $0.slot < $1.slot } }
    public func lease(for key: DecoderKey) -> DecoderLease? { byKey[key] }

    public func isCurrent(_ lease: DecoderLease) -> Bool {
        byKey[lease.key] == lease
    }

    /// Returns the existing lease for `key`, or takes a free slot.
    public mutating func acquire(_ key: DecoderKey) -> Result<DecoderLease, PoolError> {
        if let existing = byKey[key] { return .success(existing) }
        guard let slot = slots.firstIndex(where: { $0 == nil }) else { return .failure(.exhausted) }
        let lease = DecoderLease(key: key, slot: slot, generation: nextGeneration)
        // UInt64 generations cannot realistically wrap (one per prepare);
        // `&+` documents that wrapping, not trapping, is the fallback.
        nextGeneration &+= 1
        slots[slot] = lease
        byKey[key] = lease
        return .success(lease)
    }

    /// Frees the slot only if `lease` is still the current holder.
    /// Returns `false` (and changes nothing) for a stale or unknown lease.
    @discardableResult
    public mutating func release(_ lease: DecoderLease) -> Bool {
        guard isCurrent(lease), slots.indices.contains(lease.slot), slots[lease.slot] == lease else {
            return false
        }
        slots[lease.slot] = nil
        byKey[lease.key] = nil
        return true
    }

    /// Internal consistency: every slot entry is indexed and vice versa.
    public var invariantViolations: [String] {
        var problems: [String] = []
        let occupied = slots.compactMap { $0 }
        if occupied.count != byKey.count { problems.append("slot count \(occupied.count) != index count \(byKey.count)") }
        if byKey.count > capacity { problems.append("in use \(byKey.count) > capacity \(capacity)") }
        for lease in occupied where byKey[lease.key] != lease { problems.append("slot \(lease.slot) not indexed") }
        return problems
    }
}
