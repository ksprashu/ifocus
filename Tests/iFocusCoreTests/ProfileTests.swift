import CoreGraphics
import Foundation
import Testing
@testable import iFocusCore

@Suite("Profile")
struct ProfileTests {
    @Test("T14 profile roundtrip camera mismatch and rearranged bounds")
    func t14RoundtripCameraAndRearrangedBounds() throws {
        var user = SyntheticUser(seed: 1)
        guard case .success(let profile) = user.calibrate(rig: Rig.deskThree, cameraUniqueID: "cam-A", noise: false) else {
            Issue.record("Calibration failed")
            return
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(profile)
        let decoded = try JSONDecoder().decode(CalibrationProfile.self, from: data)
        #expect(decoded == profile)
        #expect(decoded.validate(activeCameraUniqueID: "cam-A") == nil)

        // Different camera ID invalidates
        let mismatch = decoded.validate(activeCameraUniqueID: "cam-B")
        #expect(mismatch == .cameraMismatch(expected: "cam-B", actual: "cam-A"))

        // Rearranged display bounds with same UUIDs still maps cleanly
        var rearranged = Rig.deskThree.topology
        rearranged.displays[0].bounds = CGRect(x: 500, y: 500, width: 3840, height: 2160)
        let f = user.features(lookingAtUV: (0.5, 0.5), on: Rig.deskThree.displays[0], rig: Rig.deskThree, timestamp: 1.0, noise: false)
        let cond = ConditionedFeatures(timestamp: 1.0, yaw: f.yaw, pitch: f.pitch, eye: EyeOffset(x: f.eyeX ?? 0, y: f.eyeY ?? 0), confidence: 0.95, faceCount: 1)
        let obs = CalibrationMapper.map(cond, topology: rearranged, profile: decoded, previousDisplayUUID: nil, config: Config())
        guard case .point(let pt) = obs else {
            Issue.record("Expected point after rearranged bounds, got \(obs)")
            return
        }
        #expect(pt.displayUUID == "disp-main")
        #expect(abs(pt.point.x - 2420) < 250)
        #expect(abs(pt.point.y - 1580) < 250)
    }

    @Test("T50 profile invariant validation rejects corrupted profiles")
    func t50InvalidProfilesRejected() throws {
        var user = SyntheticUser(seed: 1)
        guard case .success(let valid) = user.calibrate(rig: Rig.dualExternal, cameraUniqueID: "cam-1", noise: false) else {
            Issue.record("Calibration failed")
            return
        }

        // 1. Non-finite weight
        var badNaN = valid
        badNaN.models["disp-left"]?.weightsU[0] = .nan
        #expect(badNaN.validate() == .nonFiniteValue)

        // 2. Oversized weight (> 100)
        var badBig = valid
        badBig.models["disp-left"]?.weightsU[1] = 150.0
        #expect(badBig.validate() != nil)

        // 3. Wrong-length weights
        var badLen = valid
        badLen.models["disp-left"]?.weightsV = [0.0, 1.0]
        #expect(badLen.validate() != nil)

        // 4. Non-positive std deviation
        var badStd = valid
        badStd.models["disp-left"]?.featureStds[0] = 0.0
        #expect(badStd.validate() == .nonPositiveDeviation(displayUUID: "disp-left"))

        // Verify ProfileStore.load rejects corrupted JSON and leaves pipeline uncalibrated
        let tmpTemplate = "/tmp/ifocus-t50-XXXXXX"
        var buf = Array(tmpTemplate.utf8CString)
        guard let dirCStr = mkdtemp(&buf) else {
            Issue.record("mkdtemp failed")
            return
        }
        let dirURL = URL(fileURLWithPath: String(cString: dirCStr), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        let store = ProfileStore(fileStore: SecureFileStore(directoryURL: dirURL))
        let encodedBad = try JSONEncoder().encode(badBig)
        try store.fileStore.write(encodedBad, to: ProfileStore.filename)
        let loadResult = store.load(activeCameraUniqueID: "cam-1")
        #expect(loadResult.profile == nil)
        #expect(loadResult.error != nil)

        var pipe = FocusPipeline(config: Config(), profile: badBig)
        let snap = WindowSnapshot(windows: Rig.dualExternal.windows, frontmostPID: 1001, frontmostBundleID: "com.mitchellh.ghostty", focusedWindowID: Rig.dualLeftTopID, takenAt: 1.0)
        let env = PipelineEnvironment(snapshot: snap, topology: Rig.dualExternal.topology, input: InputActivity(), isPaused: false, isSessionActive: true, now: 1.0)
        let out = pipe.ingest(.features(GazeFeatures(timestamp: 1.0, yaw: 0, pitch: 0, eyeX: 0, eyeY: 0)), env: env)
        #expect(out.veto == .uncalibrated)
        #expect(out.action == .none)
    }
}
