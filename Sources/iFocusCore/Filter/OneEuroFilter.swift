import Foundation

public struct OneEuroFilter: Sendable, Equatable {
    public let minCutoff: Double
    public let beta: Double
    public let dCutoff: Double

    private var xHat: Double?
    private var dxHat: Double = 0
    private var lastTime: TimeInterval?

    public init(minCutoff: Double, beta: Double, dCutoff: Double = 1.0) {
        self.minCutoff = max(minCutoff, 1e-4)
        self.beta = max(beta, 0)
        self.dCutoff = max(dCutoff, 1e-4)
    }

    public mutating func reset() {
        xHat = nil
        dxHat = 0
        lastTime = nil
    }

    public mutating func filter(_ x: Double, at t: TimeInterval) -> Double {
        guard x.isFinite, t.isFinite else {
            return xHat ?? 0
        }

        guard let prevX = xHat, let prevT = lastTime else {
            xHat = x
            dxHat = 0
            lastTime = t
            return x
        }

        let dt = t - prevT
        guard dt > 0, dt.isFinite else {
            return prevX
        }

        if dt > 0.5 {
            xHat = x
            dxHat = 0
            lastTime = t
            return x
        }

        let dx = (x - prevX) / dt
        let aD = Self.smoothingAlpha(cutoff: dCutoff, dt: dt)
        let filteredDX = aD * dx + (1.0 - aD) * dxHat
        let cutoff = minCutoff + beta * abs(filteredDX)
        let a = Self.smoothingAlpha(cutoff: cutoff, dt: dt)
        let filteredX = a * x + (1.0 - a) * prevX

        dxHat = filteredDX
        xHat = filteredX
        lastTime = t
        return filteredX
    }

    private static func smoothingAlpha(cutoff: Double, dt: TimeInterval) -> Double {
        let safeCutoff = max(cutoff, 1e-4)
        let tau = 1.0 / (2.0 * Double.pi * safeCutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}
