/// Deterministic noise for the synthetic fixtures, so a failure is always the
/// same failure.
struct Rand {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFF) / Double(0xFFFF)
    }
}
