import CoreGraphics
import Foundation
import Testing
@testable import iFocusCore

@Suite("Calibration")
struct CalibrationTests {
    @Test("T07 noise-free deskThree calibration accuracy")
    func t07NoiseFreeAccuracy() {
        let rig = Rig.deskThree
        var user = SyntheticUser(seed: 1)
        let result = user.calibrate(rig: rig, noise: false)
        guard case .success(let profile) = result else {
            Issue.record("Noise-free calibration failed: \(result)")
            return
        }

        let testUVs: [(Double, Double)] = [
            (0.25, 0.25), (0.75, 0.25), (0.50, 0.50), (0.25, 0.75), (0.75, 0.75),
        ]
        let config = Config()

        for simDisp in rig.displays {
            var maxErr = 0.0
            for (u, v) in testUVs {
                let raw = user.features(
                    lookingAtUV: (u, v),
                    on: simDisp,
                    rig: rig,
                    pass: .natural,
                    timestamp: 100.0,
                    noise: false
                )
                let conditioned = ConditionedFeatures(
                    timestamp: 100.0,
                    yaw: raw.yaw,
                    pitch: raw.pitch,
                    eye: EyeOffset(x: raw.eyeX ?? 0, y: raw.eyeY ?? 0),
                    confidence: raw.confidence,
                    faceCount: raw.faceCount
                )
                let obs = CalibrationMapper.map(
                    conditioned,
                    topology: rig.topology,
                    profile: profile,
                    previousDisplayUUID: nil,
                    config: config
                )
                guard case .point(let pt) = obs else {
                    Issue.record("Expected point on \(simDisp.descriptor.uuid) for (\(u), \(v)), got \(obs)")
                    continue
                }
                #expect(pt.displayUUID == simDisp.descriptor.uuid)
                let predU = Double((pt.point.x - simDisp.descriptor.bounds.minX) / simDisp.descriptor.bounds.width)
                let predV = Double((pt.point.y - simDisp.descriptor.bounds.minY) / simDisp.descriptor.bounds.height)
                let err = hypot(predU - u, predV - v)
                maxErr = max(maxErr, err)
            }
            #expect(maxErr <= 0.08)
        }
    }

    @Test("T08 noisy calibration across 20 seeds")
    func t08NoisyCalibration20Seeds() {
        let rig = Rig.deskThree
        let config = Config()
        let testUVs: [(Double, Double)] = [(0.25, 0.30), (0.75, 0.30), (0.30, 0.70), (0.75, 0.70)]

        var totalError = 0.0
        var totalPoints = 0

        for seed in UInt64(1)...20 {
            var user = SyntheticUser(seed: seed)
            let result = user.calibrate(rig: rig, config: config, noise: true)
            guard case .success(let profile) = result else {
                Issue.record("Calibration failed on seed \(seed): \(result)")
                return
            }

            for simDisp in rig.displays {
                for (u, v) in testUVs {
                    var pipe = GazeFeaturePipeline()
                    var lastCond: ConditionedFeatures?
                    for frame in 0..<20 {
                        let f = user.features(
                            lookingAtUV: (u, v),
                            on: simDisp,
                            rig: rig,
                            pass: .natural,
                            timestamp: Double(frame) * 0.05,
                            noise: true
                        )
                        lastCond = pipe.process(f, config: config)
                    }
                    guard let cond = lastCond else { continue }
                    let obs = CalibrationMapper.map(
                        cond,
                        topology: rig.topology,
                        profile: profile,
                        previousDisplayUUID: simDisp.descriptor.uuid,
                        config: config
                    )
                    if case .point(let pt) = obs, pt.displayUUID == simDisp.descriptor.uuid {
                        let predU = Double((pt.point.x - simDisp.descriptor.bounds.minX) / simDisp.descriptor.bounds.width)
                        let predV = Double((pt.point.y - simDisp.descriptor.bounds.minY) / simDisp.descriptor.bounds.height)
                        totalError += hypot(predU - u, predV - v)
                        totalPoints += 1
                    } else {
                        totalError += 1.0
                        totalPoints += 1
                    }
                }
            }
        }

        let meanError = totalError / Double(max(totalPoints, 1))
        #expect(meanError <= 0.12)
    }

    @Test("T09 calibration rejection rules and barely moved head")
    func t09RejectionRulesAndBarelyMovedHead() {
        let uuid = "disp-main"
        func makeSample(u: Double, v: Double, yaw: Double, pitch: Double, eyeX: Double, eyeY: Double, t: Double) -> CalibrationSample {
            CalibrationSample(
                target: CalibrationTarget(displayUUID: uuid, u: u, v: v, pass: .natural),
                features: GazeFeatures(timestamp: t, yaw: yaw, pitch: pitch, roll: 0, eyeX: eyeX, eyeY: eyeY, confidence: 0.95, faceCount: 1)
            )
        }

        // Fewer than 4 distinct targets
        var few: [CalibrationSample] = []
        for (idx, uv) in [(0.1, 0.1), (0.9, 0.1), (0.5, 0.9)].enumerated() {
            for k in 0..<8 {
                few.append(makeSample(u: uv.0, v: uv.1, yaw: uv.0 - 0.5, pitch: uv.1 - 0.5, eyeX: uv.0 - 0.5, eyeY: 0.5 - uv.1, t: Double(idx * 10 + k) * 0.05))
            }
        }
        #expect(CalibrationSolver.solve(samples: few, cameraUniqueID: "cam", createdAt: 1.0) == .failure(.tooFewTargets))

        // Collinear targets
        var collinear: [CalibrationSample] = []
        for (idx, u) in [0.1, 0.3, 0.6, 0.9].enumerated() {
            for k in 0..<8 {
                collinear.append(makeSample(u: u, v: 0.5, yaw: u - 0.5, pitch: 0, eyeX: u - 0.5, eyeY: 0, t: Double(idx * 10 + k) * 0.05))
            }
        }
        #expect(CalibrationSolver.solve(samples: collinear, cameraUniqueID: "cam", createdAt: 1.0) == .failure(.collinearTargets))

        // Non-finite sample
        let corners: [(Double, Double)] = [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)]
        var withNaN: [CalibrationSample] = []
        for (idx, uv) in corners.enumerated() {
            for k in 0..<8 {
                withNaN.append(makeSample(u: uv.0, v: uv.1, yaw: uv.0 - 0.5, pitch: uv.1 - 0.5, eyeX: uv.0 - 0.5, eyeY: 0.5 - uv.1, t: Double(idx * 10 + k) * 0.05))
            }
        }
        withNaN.append(makeSample(u: 0.5, v: 0.5, yaw: .nan, pitch: 0, eyeX: 0, eyeY: 0, t: 5.0))
        #expect(CalibrationSolver.solve(samples: withNaN, cameraUniqueID: "cam", createdAt: 1.0) == .failure(.nonFinite))

        // Zero head movement returns valid model with headBarelyMoved = true
        var zeroHead: [CalibrationSample] = []
        for (idx, uv) in (corners + [(0.5, 0.5)]).enumerated() {
            for k in 0..<8 {
                zeroHead.append(makeSample(
                    u: uv.0,
                    v: uv.1,
                    yaw: 0.0,
                    pitch: 0.0,
                    eyeX: (uv.0 - 0.5) * 0.3,
                    eyeY: (0.5 - uv.1) * 0.25,
                    t: Double(idx * 10 + k) * 0.05
                ))
            }
        }
        let zeroHeadRes = CalibrationSolver.solve(samples: zeroHead, cameraUniqueID: "cam", createdAt: 1.0)
        guard case .success(let zeroHeadProfile) = zeroHeadRes,
              let model = zeroHeadProfile.models[uuid] else {
            Issue.record("Zero head movement should succeed, got \(zeroHeadRes)")
            return
        }
        #expect(model.headBarelyMoved == true)
        #expect(model.featureStds.allSatisfy { $0 > 0 && $0.isFinite })
    }

    @Test("T10 eyes-only glance requires eyes-only calibration pass")
    func t10EyesOnlyGlanceRequiresEyesOnlyPass() {
        let rig = Rig.dualExternal
        let config = Config()

        var userWith = SyntheticUser(seed: 11)
        guard case .success(let profWith) = userWith.calibrate(rig: rig, config: config, includeEyesOnlyPass: true, noise: false) else {
            Issue.record("Calibration with eyes-only failed")
            return
        }

        var userWithout = SyntheticUser(seed: 11)
        guard case .success(let profWithout) = userWithout.calibrate(rig: rig, config: config, includeEyesOnlyPass: false, noise: false) else {
            Issue.record("Calibration without eyes-only failed")
            return
        }

        // Eyes-only glance (head share 0): head stays neutral straight ahead (0, 0),
        // while eyes glance at dualLeftRightApp2 (1380, 300).
        let targetWin = rig.windows.first { $0.windowID == Rig.dualLeftRightApp2ID }!
        let targetPt = CGPoint(x: 1380, y: 300)

        var probeUser = SyntheticUser(seed: 99)
        let f = probeUser.features(
            lookingAtGlobalPoint: targetPt,
            rig: rig,
            headShareOverride: 0.0,
            timestamp: 10.0,
            noise: false
        )
        let cond = ConditionedFeatures(
            timestamp: 10.0,
            yaw: f.yaw,
            pitch: f.pitch,
            eye: EyeOffset(x: f.eyeX ?? 0, y: f.eyeY ?? 0),
            confidence: 0.95,
            faceCount: 1
        )
        let snapshot = WindowSnapshot(windows: rig.windows, frontmostPID: 1001, frontmostBundleID: "com.mitchellh.ghostty", focusedWindowID: Rig.dualLeftTopID, takenAt: 10.0)

        let obsWith = CalibrationMapper.map(cond, topology: rig.topology, profile: profWith, previousDisplayUUID: "disp-left", config: config)
        let obsWithout = CalibrationMapper.map(cond, topology: rig.topology, profile: profWithout, previousDisplayUUID: "disp-left", config: config)

        guard case .point(let ptWith) = obsWith else {
            Issue.record("Expected point with eyes-only pass, got \(obsWith)")
            return
        }
        let hitWith = WindowHitTester.hitTest(ptWith.point, in: snapshot, config: config)
        #expect(hitWith == .window(targetWin))

        if case .point(let ptWithout) = obsWithout {
            let hitWithout = WindowHitTester.hitTest(ptWithout.point, in: snapshot, config: config)
            #expect(hitWithout != .window(targetWin))
        }
    }

    @Test("T11 long blink falls back to head-only model and selects display")
    func t11LongBlinkHeadOnlyDisplaySelection() {
        let rig = Rig.deskThree
        let config = Config()
        var user = SyntheticUser(seed: 17)
        guard case .success(let profile) = user.calibrate(rig: rig, config: config, noise: false) else {
            Issue.record("Calibration failed")
            return
        }

        var pipeline = GazeFeaturePipeline()
        // Initial frame with open eyes at portrait display center
        let portrait = rig.display(uuid: "disp-portrait")!
        let open = user.features(lookingAtUV: (0.5, 0.5), on: portrait, rig: rig, timestamp: 0.0, eyesOpen: true, noise: false)
        _ = pipeline.process(open, config: config)

        // Long blink (> eyeHoldSeconds = 0.30 s)
        let blink = user.features(lookingAtUV: (0.5, 0.5), on: portrait, rig: rig, timestamp: 0.50, eyesOpen: false, noise: false)
        let cond = pipeline.process(blink, config: config)
        #expect(cond.eye == nil)

        let obs = CalibrationMapper.map(cond, topology: rig.topology, profile: profile, previousDisplayUUID: nil, config: config)
        guard case .point(let pt) = obs else {
            Issue.record("Expected head-only point, got \(obs)")
            return
        }
        #expect(pt.usedHeadOnlyModel == true)
        #expect(pt.displayUUID == "disp-portrait")
    }
}
