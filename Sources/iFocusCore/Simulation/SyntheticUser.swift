import CoreGraphics
import Foundation

public struct SyntheticUser: Sendable {
    public var headShare: Double
    public var headNoiseRadians: Double
    public var eyeNoiseWidths: Double
    public var rng: SeededRNG

    public init(
        seed: UInt64 = 42,
        headShare: Double = 0.6,
        headNoiseDegrees: Double = 1.5,
        eyeNoiseWidths: Double = 0.03
    ) {
        self.rng = SeededRNG(seed: seed)
        self.headShare = headShare
        self.headNoiseRadians = headNoiseDegrees * Double.pi / 180.0
        self.eyeNoiseWidths = eyeNoiseWidths
    }

    public mutating func features(
        lookingAt worldTarget: Vec3,
        eyePositionMM: Vec3 = Vec3(x: 0, y: 0, z: 0),
        headAnchorPoint: Vec3? = nil,
        headShareOverride: Double? = nil,
        timestamp: TimeInterval,
        eyesOpen: Bool = true,
        faceCount: Int = 1,
        confidence: Double = 0.95,
        noise: Bool = true
    ) -> GazeFeatures {
        let targetAngles = gazeAngles(from: eyePositionMM, to: worldTarget)
        let effectiveShare = headShareOverride ?? headShare

        let headYaw: Double
        let headPitch: Double
        if let anchor = headAnchorPoint {
            let anchorAngles = gazeAngles(from: eyePositionMM, to: anchor)
            headYaw = effectiveShare * anchorAngles.yaw
            headPitch = effectiveShare * anchorAngles.pitch
        } else {
            headYaw = effectiveShare * targetAngles.yaw
            headPitch = effectiveShare * targetAngles.pitch
        }

        let eyeYaw = targetAngles.yaw - headYaw
        let eyePitch = targetAngles.pitch - headPitch

        let noiseYaw = noise ? rng.nextGaussian(stdDev: headNoiseRadians) : 0
        let noisePitch = noise ? rng.nextGaussian(stdDev: headNoiseRadians) : 0

        let eyeX: Double?
        let eyeY: Double?
        if eyesOpen {
            let cleanEyeX = 0.43 * sin(eyeYaw)
            let cleanEyeY = 0.43 * sin(-eyePitch)
            let nX = noise ? rng.nextGaussian(stdDev: eyeNoiseWidths) : 0
            let nY = noise ? rng.nextGaussian(stdDev: eyeNoiseWidths) : 0
            eyeX = cleanEyeX + nX
            eyeY = cleanEyeY + nY
        } else {
            eyeX = nil
            eyeY = nil
        }

        return GazeFeatures(
            timestamp: timestamp,
            yaw: headYaw + noiseYaw,
            pitch: headPitch + noisePitch,
            roll: 0,
            eyeX: eyeX,
            eyeY: eyeY,
            faceCenter: CGPoint(x: 0.5, y: 0.5),
            faceScale: 0.25,
            confidence: confidence,
            faceCount: faceCount
        )
    }

    public mutating func features(
        lookingAtUV uv: (u: Double, v: Double),
        on display: SimDisplay,
        rig: SimRig,
        pass: CalibrationPass = .natural,
        timestamp: TimeInterval,
        eyesOpen: Bool = true,
        faceCount: Int = 1,
        confidence: Double = 0.95,
        noise: Bool = true
    ) -> GazeFeatures {
        let target = display.worldPoint(u: uv.u, v: uv.v)
        let anchor: Vec3? = (pass == .eyesOnly) ? display.worldPoint(u: 0.5, v: 0.5) : nil
        return features(
            lookingAt: target,
            eyePositionMM: rig.eyePositionMM,
            headAnchorPoint: anchor,
            timestamp: timestamp,
            eyesOpen: eyesOpen,
            faceCount: faceCount,
            confidence: confidence,
            noise: noise
        )
    }

    public mutating func features(
        lookingAtGlobalPoint point: CGPoint,
        rig: SimRig,
        headShareOverride: Double? = nil,
        headAnchorPoint: Vec3? = nil,
        timestamp: TimeInterval,
        eyesOpen: Bool = true,
        faceCount: Int = 1,
        confidence: Double = 0.95,
        noise: Bool = true
    ) -> GazeFeatures {
        let target = rig.worldPoint(forGlobalPoint: point) ?? Vec3(x: 0, y: 0, z: 650)
        return features(
            lookingAt: target,
            eyePositionMM: rig.eyePositionMM,
            headAnchorPoint: headAnchorPoint,
            headShareOverride: headShareOverride,
            timestamp: timestamp,
            eyesOpen: eyesOpen,
            faceCount: faceCount,
            confidence: confidence,
            noise: noise
        )
    }

    public mutating func calibrate(
        rig: SimRig,
        config: Config = Config(),
        cameraUniqueID: String = "sim-camera",
        includeEyesOnlyPass: Bool = true,
        noise: Bool = true,
        fps: Double = 20.0
    ) -> Result<CalibrationProfile, CalibrationError> {
        let plan = CalibrationPlan.standard(for: rig.topology, includeEyesOnlyPass: includeEyesOnlyPass)
        var session = CalibrationSession(plan: plan, minConfidence: config.minConfidence)
        let dt = 1.0 / fps
        var t = 0.0

        while !session.isFinished {
            guard let target = session.currentTarget,
                  let display = rig.display(uuid: target.displayUUID) else {
                break
            }
            let sample = features(
                lookingAtUV: (target.u, target.v),
                on: display,
                rig: rig,
                pass: target.pass,
                timestamp: t,
                noise: noise
            )
            let progress = session.ingest(sample)
            if case .failed(let err) = progress {
                return .failure(err)
            }
            t += dt
        }

        return session.solve(cameraUniqueID: cameraUniqueID, createdAt: t, config: config)
    }

    private func gazeAngles(from eye: Vec3, to target: Vec3) -> (yaw: Double, pitch: Double) {
        let d = target - eye
        let yaw = atan2(d.x, d.z)
        let horiz = hypot(d.x, d.z)
        // Vision convention: positive pitch = nodding head down (-y)
        let pitch = atan2(-d.y, horiz)
        return (yaw, pitch)
    }
}
