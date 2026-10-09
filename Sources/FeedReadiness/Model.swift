import Foundation

/// Stable identity of one item in the feed.
public struct ItemID: Hashable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { self.raw = value }
    public var description: String { raw }
    public static func < (lhs: ItemID, rhs: ItemID) -> Bool { lhs.raw < rhs.raw }
}

/// One encoded variant of an item (an HLS variant or a progressive file).
public struct Rendition: Hashable, Sendable, Identifiable {
    public let id: String
    public let height: Int
    public let bitrateKbps: Int

    public init(id: String, height: Int, bitrateKbps: Int) {
        self.id = id
        self.height = max(0, height)
        self.bitrateKbps = max(0, bitrateKbps)
    }

    /// Bytes per second of media at this bitrate (kbps * 1000 / 8).
    public var bytesPerSecond: Int64 {
        Saturating.multiply(Int64(bitrateKbps), 125)
    }

    /// Bytes needed for `seconds` of media. Non-finite or negative seconds map to 0.
    public func bytes(forSeconds seconds: Double) -> Int64 {
        let safeSeconds = seconds.sanitized(in: 0 ... 86_400, fallback: 0)
        return Saturating.nonNegativeInt64(safeSeconds * Double(bytesPerSecond))
    }
}

/// One feed entry. Renditions are normalised on init: zero-bitrate and
/// duplicate ids are dropped and the rest are sorted by ascending bitrate,
/// so "the best rendition under a cap" is a single reverse scan.
public struct FeedItem: Hashable, Sendable, Identifiable {
    public let id: ItemID
    public let renditions: [Rendition]
    public let durationSeconds: Double

    public init(id: ItemID, renditions: [Rendition], durationSeconds: Double) {
        self.id = id
        var seen = Set<String>()
        self.renditions = renditions
            .filter { $0.bitrateKbps > 0 && seen.insert($0.id).inserted }
            .sorted { ($0.bitrateKbps, $0.id) < ($1.bitrateKbps, $1.id) }
        self.durationSeconds = durationSeconds.sanitized(in: 0 ... 86_400, fallback: 0)
    }

    /// An item with no usable rendition can never be played or prefetched.
    public var isPlayable: Bool { !renditions.isEmpty }

    /// Highest rendition whose bitrate is at or under `capKbps`. When every
    /// rendition is above the cap the lowest one is returned: a capped feed
    /// degrades quality, it never refuses to play. `nil` only when unplayable.
    public func rendition(cappedAt capKbps: Int) -> Rendition? {
        renditions.last(where: { $0.bitrateKbps <= capKbps }) ?? renditions.first
    }

    /// Size of the whole item at `rendition`.
    public func fullBytes(at rendition: Rendition) -> Int64 {
        rendition.bytes(forSeconds: durationSeconds)
    }
}

/// Cache identity: bytes are stored per (item, rendition), because a quality
/// change makes the bytes of the old rendition useless for the new one.
public struct CacheKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let item: ItemID
    public let rendition: String
    public init(item: ItemID, rendition: String) {
        self.item = item
        self.rendition = rendition
    }
    public var description: String { "\(item.raw)@\(rendition)" }
    public static func < (lhs: CacheKey, rhs: CacheKey) -> Bool {
        (lhs.item.raw, lhs.rendition) < (rhs.item.raw, rhs.rendition)
    }
}

// MARK: - Device conditions

/// Network class, ordered from worst to best.
public enum NetworkClass: Int, Sendable, CaseIterable, Comparable {
    case offline = 0, constrained, cellular, wifi
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// Mirrors `ProcessInfo.ThermalState`, ordered from best to worst.
public enum ThermalLevel: Int, Sendable, CaseIterable, Comparable {
    case nominal = 0, fair, serious, critical
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// Memory pressure as reported by the OS, ordered from best to worst.
public enum MemoryPressure: Int, Sendable, CaseIterable, Comparable {
    case normal = 0, warning, critical
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// Everything the engine reacts to, as one value so a policy is a pure function.
public struct DeviceConditions: Hashable, Sendable {
    public var network: NetworkClass
    /// Recently measured throughput. Negative values are stored as 0.
    public var throughputKbps: Int
    public var lowPowerMode: Bool
    public var thermal: ThermalLevel
    public var memory: MemoryPressure

    public init(
        network: NetworkClass = .wifi,
        throughputKbps: Int = 20_000,
        lowPowerMode: Bool = false,
        thermal: ThermalLevel = .nominal,
        memory: MemoryPressure = .normal
    ) {
        self.network = network
        self.throughputKbps = max(0, throughputKbps)
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.memory = memory
    }

    public static let ideal = DeviceConditions()

    /// True when `self` is at least as bad as `other` in every dimension the
    /// window policy reads. Throughput is excluded: it drives the quality
    /// ladder, not the window. This partial order is what the monotonicity
    /// audit is defined over.
    public func isNoBetter(than other: DeviceConditions) -> Bool {
        network <= other.network
            && thermal >= other.thermal
            && memory >= other.memory
            && (lowPowerMode || !other.lowPowerMode)
    }
}
