import Foundation
import Testing
@testable import iFocusCore

@Suite("OneEuro")
struct OneEuroTests {
    @Test("T04 static signal noise variance reduction")
    func t04VarianceReduction() {
        var rng = SeededRNG(seed: 12345)
        var filter = OneEuroFilter(minCutoff: 1.2, beta: 4.0, dCutoff: 1.0)
        let n = 400
        let dt = 0.05 // 20 Hz

        var rawSamples: [Double] = []
        var filteredSamples: [Double] = []

        for i in 0..<n {
            let noise = rng.nextGaussian(mean: 0, stdDev: 0.01)
            rawSamples.append(noise)
            filteredSamples.append(filter.filter(noise, at: Double(i) * dt))
        }

        // Skip initial transient (first 20 samples = 1s)
        let rawTail = Array(rawSamples.dropFirst(20))
        let filtTail = Array(filteredSamples.dropFirst(20))

        func variance(_ xs: [Double]) -> Double {
            let m = xs.reduce(0, +) / Double(xs.count)
            return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)
        }

        let inVar = variance(rawTail)
        let outVar = variance(filtTail)
        #expect(inVar > 0)
        #expect(outVar <= 0.35 * inVar)
    }

    @Test("T05 step response 90 percent within 150ms")
    func t05StepResponse() {
        var filter = OneEuroFilter(minCutoff: 1.2, beta: 4.0, dCutoff: 1.0)
        let dt = 0.05 // 20 Hz
        var t = 0.0
        for _ in 0..<10 {
            _ = filter.filter(0.0, at: t)
            t += dt
        }

        let stepStart = t
        var reachedAt: TimeInterval?
        for _ in 0..<10 {
            let y = filter.filter(0.5, at: t)
            if y >= 0.45 && reachedAt == nil {
                reachedAt = t - stepStart
            }
            t += dt
        }

        #expect(reachedAt != nil)
        #expect((reachedAt ?? 999) <= 0.15 + 1e-9)
    }

    @Test("T06 edge inputs never yield non-finite")
    func t06EdgeInputsFinite() {
        var filter = OneEuroFilter(minCutoff: 1.2, beta: 4.0, dCutoff: 1.0)
        let first = filter.filter(0.25, at: 1.0)
        #expect(first.isFinite)

        // dt <= 0
        let sameTime = filter.filter(0.99, at: 1.0)
        #expect(sameTime == first)
        let backTime = filter.filter(0.99, at: 0.5)
        #expect(backTime == first)

        // NaN and +/- infinity
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            let out = filter.filter(bad, at: 1.05)
            #expect(out.isFinite)
            #expect(out == first)
        }
        let badTime = filter.filter(0.5, at: .nan)
        #expect(badTime.isFinite)

        // 1 s gap (> 0.5 s) resets cleanly to new sample
        let afterGap = filter.filter(-0.4, at: 2.5)
        #expect(afterGap.isFinite)
        #expect(abs(afterGap - (-0.4)) < 1e-9)
    }
}
