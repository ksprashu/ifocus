import Foundation
import Testing
@testable import iFocusCore

@Suite("FeaturePipeline")
struct FeaturePipelineTests {
    @Test("T47 blink hold and eye dropout fallback")
    func t47BlinkHoldAndDwell() {
        let config = Config()
        var pipeline = GazeFeaturePipeline()

        // Steady eye gaze before blink
        var lastConditioned: ConditionedFeatures?
        for i in 0..<6 {
            let f = GazeFeatures(timestamp: Double(i) * 0.05, yaw: 0.1, pitch: 0.0, eyeX: 0.12, eyeY: -0.04)
            lastConditioned = pipeline.process(f, config: config)
        }
        let heldReference = lastConditioned?.eye
        #expect(heldReference != nil)

        // Blink for 0.15 s (<= eyeHoldSeconds = 0.30): eye must remain held
        let duringBlink = pipeline.process(
            GazeFeatures(timestamp: 0.40, yaw: 0.1, pitch: 0.0, eyeX: nil, eyeY: nil),
            config: config
        )
        #expect(duringBlink.eye == heldReference)

        // Longer than eyeHoldSeconds (> 0.30s since last valid eye at t = 0.25): eye becomes nil
        let afterHold = pipeline.process(
            GazeFeatures(timestamp: 0.60, yaw: 0.1, pitch: 0.0, eyeX: nil, eyeY: nil),
            config: config
        )
        #expect(afterHold.eye == nil)

        // Also prove a 150 ms blink in the middle of a dwell does not delay switch by > 1 frame
        let rig = Rig.dualExternal
        var user = SyntheticUser(seed: 7)
        guard case .success(let profile) = user.calibrate(rig: rig, noise: false) else {
            Issue.record("Calibration failed")
            return
        }

        let noBlinkScenario = Scenario(
            name: "no-blink",
            rig: rig,
            initialFocusedWindowID: Rig.dualLeftTopID,
            duration: 1.5,
            segments: [ScenarioSegment(startTime: 0, endTime: 1.5, target: .window(Rig.dualRightRightID), eyesOpen: true)],
            expectedSwitches: [Rig.dualRightRightID],
            noise: false
        )
        let blinkScenario = Scenario(
            name: "with-blink",
            rig: rig,
            initialFocusedWindowID: Rig.dualLeftTopID,
            duration: 1.5,
            segments: [
                ScenarioSegment(startTime: 0, endTime: 0.14, target: .window(Rig.dualRightRightID), eyesOpen: true),
                ScenarioSegment(startTime: 0.14, endTime: 0.29, target: .window(Rig.dualRightRightID), eyesOpen: false),
                ScenarioSegment(startTime: 0.29, endTime: 1.5, target: .window(Rig.dualRightRightID), eyesOpen: true),
            ],
            expectedSwitches: [Rig.dualRightRightID],
            noise: false
        )
        _ = profile
        guard case .success(let resNoBlink) = ScenarioRunner.run(noBlinkScenario, seed: 7, config: config),
              case .success(let resBlink) = ScenarioRunner.run(blinkScenario, seed: 7, config: config) else {
            Issue.record("ScenarioRunner failed")
            return
        }
        #expect(resNoBlink.passed)
        #expect(resBlink.passed)
        let tNoBlink = resNoBlink.switchTimestamps[0].timestamp
        let tBlink = resBlink.switchTimestamps[0].timestamp
        #expect(abs(tBlink - tNoBlink) <= 0.05 + 1e-6)
    }

    @Test("T74 FrameDecimator decimates 30Hz to 20Hz accepts 15Hz and reanchors after 1s gap")
    func t74FrameDecimatorRatesAndReanchor() {
        // 30 Hz for 10 s at target 20 -> 195...205 accepted
        var dec30 = FrameDecimator(targetFPS: 20)
        var accepted30 = 0
        for i in 0..<300 {
            if dec30.shouldProcess(at: Double(i) / 30.0) {
                accepted30 += 1
            }
        }
        #expect(accepted30 >= 195 && accepted30 <= 205)

        // 15 Hz for 10 s at target 20 -> all 150 accepted
        var dec15 = FrameDecimator(targetFPS: 20)
        var accepted15 = 0
        for i in 0..<150 {
            if dec15.shouldProcess(at: Double(i) / 15.0) {
                accepted15 += 1
            }
        }
        #expect(accepted15 == 150)

        // 1 s gap (> 0.25 s) re-anchors phase without accepting a backlog burst immediately after
        var decGap = FrameDecimator(targetFPS: 20)
        #expect(decGap.shouldProcess(at: 0.00) == true)
        #expect(decGap.shouldProcess(at: 1.00) == true)
        #expect(decGap.shouldProcess(at: 1.01) == false)
        #expect(decGap.shouldProcess(at: 1.05) == true)
    }

    @Test("T75 EyeGeometry de-roll preserves eye offset across head roll angles")
    func t75EyeGeometryDeRollInvariance() {
        func makeEllipse(center: CGPoint, rx: Double, ry: Double, count: Int) -> [CGPoint] {
            (0..<count).map { i in
                let a = (Double(i) / Double(count)) * 2.0 * Double.pi
                return CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
            }
        }
        func rotate(_ points: [CGPoint], byDegrees deg: Double) -> [CGPoint] {
            let rad = deg * Double.pi / 180.0
            let c = cos(rad)
            let s = sin(rad)
            return points.map { p in
                let x = Double(p.x)
                let y = Double(p.y)
                return CGPoint(x: x * c - y * s, y: x * s + y * c)
            }
        }

        let leftContour = makeEllipse(center: CGPoint(x: -0.20, y: 0.10), rx: 0.08, ry: 0.03, count: 16)
        let rightContour = makeEllipse(center: CGPoint(x: 0.20, y: 0.10), rx: 0.08, ry: 0.03, count: 16)
        let leftPupil = [CGPoint(x: -0.20 + 0.016, y: 0.10 - 0.012)]
        let rightPupil = [CGPoint(x: 0.20 + 0.016, y: 0.10 - 0.012)]

        guard let baseline = EyeGeometry.eyeOffset(
            leftContour: leftContour,
            leftPupil: leftPupil,
            rightContour: rightContour,
            rightPupil: rightPupil
        ) else {
            Issue.record("Baseline eyeOffset returned nil")
            return
        }
        #expect(abs(baseline.x) > 0.1)
        #expect(abs(baseline.y) > 0.05)

        for deg in [0.0, 15.0, -15.0, 30.0, -30.0] {
            guard let rotated = EyeGeometry.eyeOffset(
                leftContour: rotate(leftContour, byDegrees: deg),
                leftPupil: rotate(leftPupil, byDegrees: deg),
                rightContour: rotate(rightContour, byDegrees: deg),
                rightPupil: rotate(rightPupil, byDegrees: deg)
            ) else {
                Issue.record("Rotated eyeOffset returned nil for \(deg) deg")
                return
            }
            #expect(abs(rotated.x - baseline.x) < 1e-9)
            #expect(abs(rotated.y - baseline.y) < 1e-9)
        }
    }
}
