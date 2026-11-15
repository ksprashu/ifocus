import Foundation
import Testing
@testable import iFocusCore

@Suite("CalibrationSession")
struct CalibrationSessionTests {
    @Test("T49 calibration session settle capture repeats and plan size")
    func t49SessionPlanWindowsAndRepeats() {
        let threePlan = CalibrationPlan.standard(for: Rig.deskThree.topology)
        #expect(threePlan.count == 27) // 9 targets per display * 3 displays

        let singleDisplay = DisplayTopology(displays: [Rig.deskThree.topology.displays[0]])
        let singlePlan = CalibrationPlan.standard(for: singleDisplay)
        #expect(singlePlan.count == 9)

        // Verify settle window collects 0 samples, second face ignored, low confidence ignored,
        // and fewer than 8 samples repeats 3 times then fails on 4th.
        var session = CalibrationSession(plan: singlePlan, settle: 0.6, capture: 0.8, minSamples: 8, minConfidence: 0.5)

        // During settle (0.0 .. 0.55)
        for i in 0..<12 {
            let t = Double(i) * 0.05
            let p = session.ingest(GazeFeatures(timestamp: t, yaw: 0, pitch: 0, eyeX: 0, eyeY: 0, confidence: 0.95, faceCount: 1))
            if case .settling = p {
                // expected
            } else {
                Issue.record("Expected settling at t=\(t), got \(p)")
            }
        }

        // During capture (0.60 .. 1.35): feed 10 samples with faceCount=2 and 4 valid samples -> < 8 valid
        for i in 12..<22 {
            let t = Double(i) * 0.05
            _ = session.ingest(GazeFeatures(timestamp: t, yaw: 0, pitch: 0, eyeX: 0, eyeY: 0, confidence: 0.95, faceCount: 2))
        }
        for i in 22..<26 {
            let t = Double(i) * 0.05
            let p = session.ingest(GazeFeatures(timestamp: t, yaw: 0, pitch: 0, eyeX: 0, eyeY: 0, confidence: 0.95, faceCount: 1))
            if case .capturing(_, let count, _) = p {
                #expect(count == (i - 21))
            }
        }

        // Low confidence ignored
        let lowConf = session.ingest(GazeFeatures(timestamp: 1.35, yaw: 0, pitch: 0, eyeX: 0, eyeY: 0, confidence: 0.2, faceCount: 1))
        if case .capturing(_, let count, _) = lowConf {
            #expect(count == 4)
        }

        // End capture window with only 4 valid samples -> repeat 1
        let repeat1 = session.ingest(GazeFeatures(timestamp: 1.40, yaw: 0, pitch: 0, eyeX: 0, eyeY: 0, confidence: 0.95, faceCount: 1))
        if case .repeating(_, let attempt) = repeat1 {
            #expect(attempt == 1)
        } else {
            Issue.record("Expected repeat 1, got \(repeat1)")
        }

        // Fail 3 more times (repeats 2, 3, then .failed(.insufficientSamples))
        var t = 1.40
        var lastProgress: CalibrationProgress?
        for attemptExpected in 2...4 {
            t += 1.45 // jump past settle + capture with 0 valid capture samples
            lastProgress = session.ingest(GazeFeatures(timestamp: t, yaw: 0, pitch: 0, eyeX: 0, eyeY: 0, confidence: 0.95, faceCount: 1))
            if attemptExpected <= 3 {
                if case .repeating(_, let attempt) = lastProgress {
                    #expect(attempt == attemptExpected)
                } else {
                    Issue.record("Expected repeat \(attemptExpected), got \(String(describing: lastProgress))")
                }
            }
        }
        #expect(lastProgress == .failed(.insufficientSamples))
    }
}
