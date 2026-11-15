import Foundation

public struct SeededRNG: Sendable {
    private var state: UInt64
    private var spareGaussian: Double?

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func nextDouble() -> Double {
        let bits = nextUInt64() >> 11
        return Double(bits) * (1.0 / 9_007_199_254_740_992.0) // 2^53
    }

    public mutating func nextGaussian(mean: Double = 0, stdDev: Double = 1) -> Double {
        if let spare = spareGaussian {
            spareGaussian = nil
            return mean + stdDev * spare
        }
        let u1 = max(nextDouble(), 1e-12)
        let u2 = nextDouble()
        let mag = sqrt(-2.0 * log(u1))
        let z0 = mag * cos(2.0 * Double.pi * u2)
        let z1 = mag * sin(2.0 * Double.pi * u2)
        spareGaussian = z1
        return mean + stdDev * z0
    }
}
