import Foundation

public struct GazeFeaturePipeline: Sendable, Equatable {
    private var yawFilter = OneEuroFilter(minCutoff: 1.2, beta: 4.0, dCutoff: 1.0)
    private var pitchFilter = OneEuroFilter(minCutoff: 1.2, beta: 4.0, dCutoff: 1.0)
    private var eyeXFilter = OneEuroFilter(minCutoff: 0.8, beta: 5.0, dCutoff: 1.0)
    private var eyeYFilter = OneEuroFilter(minCutoff: 0.8, beta: 5.0, dCutoff: 1.0)

    private var lastEye: EyeOffset?
    private var lastEyeTime: TimeInterval?

    public init() {}

    public mutating func reset() {
        yawFilter.reset()
        pitchFilter.reset()
        eyeXFilter.reset()
        eyeYFilter.reset()
        lastEye = nil
        lastEyeTime = nil
    }

    public mutating func process(_ f: GazeFeatures, config: Config) -> ConditionedFeatures {
        let filteredYaw = yawFilter.filter(f.yaw, at: f.timestamp)
        let filteredPitch = pitchFilter.filter(f.pitch, at: f.timestamp)

        let conditionedEye: EyeOffset?
        if let ex = f.eyeX, let ey = f.eyeY, ex.isFinite, ey.isFinite, f.timestamp.isFinite {
            let fx = eyeXFilter.filter(ex, at: f.timestamp)
            let fy = eyeYFilter.filter(ey, at: f.timestamp)
            let offset = EyeOffset(x: fx, y: fy)
            lastEye = offset
            lastEyeTime = f.timestamp
            conditionedEye = offset
        } else if let held = lastEye, let prevTime = lastEyeTime, f.timestamp.isFinite {
            let gap = f.timestamp - prevTime
            if gap >= 0 && gap <= config.eyeHoldSeconds {
                conditionedEye = held
            } else {
                conditionedEye = nil
            }
        } else {
            conditionedEye = nil
        }

        let safeConfidence: Double
        if f.confidence.isFinite {
            safeConfidence = min(max(f.confidence, 0), 1)
        } else {
            safeConfidence = 0
        }

        return ConditionedFeatures(
            timestamp: f.timestamp,
            yaw: filteredYaw,
            pitch: filteredPitch,
            eye: conditionedEye,
            confidence: safeConfidence,
            faceCount: f.faceCount
        )
    }
}
