import Foundation

/// Small deterministic generator for repeatable preview/export. This is intentionally
/// isolated because exact NumPy RNG parity is a separate porting task.
public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
    public mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-15)
        let u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
