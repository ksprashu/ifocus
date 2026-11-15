import CoreGraphics
import Foundation
import Testing
@testable import iFocusCore

@Suite("DisplaySelection")
struct DisplaySelectionTests {
    @Test("T12 display selection center edge and offscreen margins")
    func t12DisplaySelectionAndMargins() {
        let config = Config()

        for rig in [Rig.deskThree, Rig.dualExternal] {
            var user = SyntheticUser(seed: 3)
            guard case .success(let profile) = user.calibrate(rig: rig, config: config, noise: false) else {
                Issue.record("Calibration failed on \(rig.name)")
                return
            }

            for disp in rig.displays {
                for (u, v) in [(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.5, 0.05), (0.5, 0.95)] {
                    let f = user.features(lookingAtUV: (u, v), on: disp, rig: rig, timestamp: 1.0, noise: false)
                    let cond = ConditionedFeatures(
                        timestamp: 1.0,
                        yaw: f.yaw,
                        pitch: f.pitch,
                        eye: EyeOffset(x: f.eyeX ?? 0, y: f.eyeY ?? 0),
                        confidence: 0.95,
                        faceCount: 1
                    )
                    let obs = CalibrationMapper.map(cond, topology: rig.topology, profile: profile, previousDisplayUUID: nil, config: config)
                    guard case .point(let pt) = obs else {
                        Issue.record("Expected point on \(disp.descriptor.uuid) at (\(u), \(v)), got \(obs)")
                        continue
                    }
                    #expect(pt.displayUUID == disp.descriptor.uuid)
                }
            }
        }

        // Check asymmetric offscreen margins directly on single main display (699x389 mm)
        let singleDisp = Rig.deskThree.displays[0]
        let singleTopo = DisplayTopology(displays: [singleDisp.descriptor])
        var singleUser = SyntheticUser(seed: 5)
        let singleSamples = CalibrationPlan.standard(for: singleTopo).flatMap { target in
            (0..<10).map { k in
                CalibrationSample(
                    target: target,
                    features: singleUser.features(
                        lookingAtUV: (target.u, target.v),
                        on: singleDisp,
                        rig: Rig.deskThree,
                        pass: target.pass,
                        timestamp: Double(k) * 0.05,
                        noise: false
                    )
                )
            }
        }
        guard case .success(let singleProf) = CalibrationSolver.solve(samples: singleSamples, cameraUniqueID: "sim-camera", createdAt: 1.0) else {
            Issue.record("Single display solve failed")
            return
        }

        // 30 mm below panel (v > 1.0 by 30/389) -> offScreen (> offscreenMarginBottomMM = 20)
        let below30 = singleUser.features(
            lookingAtUV: (0.5, 1.0 + 30.0 / 389.0),
            on: singleDisp,
            rig: Rig.deskThree,
            timestamp: 2.0,
            noise: false
        )
        let condBelow30 = ConditionedFeatures(timestamp: 2.0, yaw: below30.yaw, pitch: below30.pitch, eye: EyeOffset(x: below30.eyeX ?? 0, y: below30.eyeY ?? 0), confidence: 0.95, faceCount: 1)
        #expect(CalibrationMapper.map(condBelow30, topology: singleTopo, profile: singleProf, previousDisplayUUID: nil, config: config) == .offScreen)

        // 100 mm below panel -> offScreen
        let below100 = singleUser.features(
            lookingAtUV: (0.5, 1.0 + 100.0 / 389.0),
            on: singleDisp,
            rig: Rig.deskThree,
            timestamp: 2.1,
            noise: false
        )
        let condBelow100 = ConditionedFeatures(timestamp: 2.1, yaw: below100.yaw, pitch: below100.pitch, eye: EyeOffset(x: below100.eyeX ?? 0, y: below100.eyeY ?? 0), confidence: 0.95, faceCount: 1)
        #expect(CalibrationMapper.map(condBelow100, topology: singleTopo, profile: singleProf, previousDisplayUUID: nil, config: config) == .offScreen)

        // 30 mm beside panel (u < 0 by 30/699) -> on-screen (<= offscreenMarginMM = 60)
        let beside30 = singleUser.features(
            lookingAtUV: (-30.0 / 699.0, 0.5),
            on: singleDisp,
            rig: Rig.deskThree,
            timestamp: 2.2,
            noise: false
        )
        let condBeside30 = ConditionedFeatures(timestamp: 2.2, yaw: beside30.yaw, pitch: beside30.pitch, eye: EyeOffset(x: beside30.eyeX ?? 0, y: beside30.eyeY ?? 0), confidence: 0.95, faceCount: 1)
        let besideObs = CalibrationMapper.map(condBeside30, topology: singleTopo, profile: singleProf, previousDisplayUUID: nil, config: config)
        if case .point(let pt) = besideObs {
            #expect(pt.displayUUID == singleDisp.descriptor.uuid)
        } else {
            Issue.record("30 mm beside panel should clamp onto display, got \(besideObs)")
        }
    }

    @Test("T13 zero physical size fallback avoids divide by zero")
    func t13ZeroPhysicalSizeFallback() {
        var topo = Rig.deskThree.topology
        for i in topo.displays.indices {
            topo.displays[i].physicalSizeMM = .zero
        }
        var user = SyntheticUser(seed: 2)
        guard case .success(let profile) = user.calibrate(rig: Rig.deskThree, noise: false) else {
            Issue.record("Calibration failed")
            return
        }
        let f = user.features(lookingAtUV: (0.5, 0.5), on: Rig.deskThree.displays[0], rig: Rig.deskThree, timestamp: 1.0, noise: false)
        let cond = ConditionedFeatures(timestamp: 1.0, yaw: f.yaw, pitch: f.pitch, eye: EyeOffset(x: f.eyeX ?? 0, y: f.eyeY ?? 0), confidence: 0.95, faceCount: 1)
        let obs = CalibrationMapper.map(cond, topology: topo, profile: profile, previousDisplayUUID: nil, config: Config())
        guard case .point(let pt) = obs else {
            Issue.record("Expected point despite zero physicalSizeMM, got \(obs)")
            return
        }
        #expect(pt.point.x.isFinite && pt.point.y.isFinite)
        #expect(pt.displayUUID == "disp-main")
    }
}
