// Saturating arithmetic for byte counts and window sizes.
//
// Byte budgets are products of user-controlled numbers (bitrate x seconds),
// and a trapping `*` or `Int64(Double)` anywhere on that path would crash
// the app on a malformed manifest. Every such operation goes through here.

enum Saturating {
    /// `a + b`, clamped to `Int64.min ... Int64.max` instead of trapping.
    static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }

    /// `a - b`, clamped instead of trapping.
    static func subtract(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return result }
        return b < 0 ? .max : .min
    }

    /// `a * b`, clamped instead of trapping.
    static func multiply(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return result }
        return (a < 0) != (b < 0) ? .min : .max
    }

    /// Non-negative `Int64` from a `Double`. NaN, negative and -inf map to 0;
    /// +inf and anything at or above 2^63 map to `Int64.max`.
    /// (`Double(Int64.max)` rounds up to exactly 2^63, so `>=` is the correct
    /// guard: every value strictly below it converts without trapping.)
    static func nonNegativeInt64(_ value: Double) -> Int64 {
        guard value.isFinite else { return value == .infinity ? .max : 0 }
        guard value > 0 else { return 0 }
        guard value < Double(Int64.max) else { return .max }
        return Int64(value)
    }

    /// Increments a counter, wrapping is impossible in practice but the
    /// counter sticks at `.max` rather than trapping.
    static func increment(_ value: inout Int) {
        if value < Int.max { value += 1 }
    }

    static func increment(_ value: inout Int64, by amount: Int64) {
        value = add(value, amount)
    }

    /// `a + b` on `Int`, clamped instead of trapping.
    static func addInt(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }

    /// `a - b` on `Int`, or `nil` on overflow (used for index distances,
    /// where an overflowing distance simply means "outside any window").
    static func distance(from a: Int, to b: Int) -> Int? {
        let (result, overflow) = b.subtractingReportingOverflow(a)
        return overflow ? nil : result
    }

    /// Decoders left for the prepared tiers once one is reserved for the
    /// playing item. Never negative, never traps (`Int.min - 1` would).
    static func spareDecoders(_ capacity: Int) -> Int {
        capacity > 0 ? capacity - 1 : 0
    }

    /// `base + offset` as an index into `0 ..< count`, or `nil` when it falls
    /// outside (including on overflow).
    static func index(_ base: Int, offset: Int, count: Int) -> Int? {
        let (result, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, result >= 0, result < count else { return nil }
        return result
    }
}

extension Double {
    /// Replaces NaN/inf with `fallback` and clamps into `range`.
    func sanitized(in range: ClosedRange<Double>, fallback: Double) -> Double {
        guard isFinite else { return fallback }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
