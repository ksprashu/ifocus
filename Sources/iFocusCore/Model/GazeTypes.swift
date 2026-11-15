import CoreGraphics
import Foundation

public struct GazeFeatures: Sendable, Equatable, Codable {
    public var timestamp: TimeInterval
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    public var eyeX: Double?
    public var eyeY: Double?
    public var faceCenter: CGPoint
    public var faceScale: Double
    public var confidence: Double
    public var faceCount: Int

    public init(
        timestamp: TimeInterval,
        yaw: Double,
        pitch: Double,
        roll: Double = 0,
        eyeX: Double? = nil,
        eyeY: Double? = nil,
        faceCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
        faceScale: Double = 0.25,
        confidence: Double = 1.0,
        faceCount: Int = 1
    ) {
        self.timestamp = timestamp
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.eyeX = eyeX
        self.eyeY = eyeY
        self.faceCenter = faceCenter
        self.faceScale = faceScale
        self.confidence = confidence
        self.faceCount = faceCount
    }
}

public enum GazeEvent: Sendable, Equatable {
    case features(GazeFeatures)
    case noFace(TimeInterval)
    case interrupted(String)
}

public struct EyeOffset: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ConditionedFeatures: Sendable, Equatable {
    public var timestamp: TimeInterval
    public var yaw: Double
    public var pitch: Double
    public var eye: EyeOffset?
    public var confidence: Double
    public var faceCount: Int

    public init(
        timestamp: TimeInterval,
        yaw: Double,
        pitch: Double,
        eye: EyeOffset?,
        confidence: Double,
        faceCount: Int
    ) {
        self.timestamp = timestamp
        self.yaw = yaw
        self.pitch = pitch
        self.eye = eye
        self.confidence = confidence
        self.faceCount = faceCount
    }
}

public struct GazePoint: Sendable, Equatable {
    public var point: CGPoint
    public var displayUUID: String
    public var confidence: Double
    public var timestamp: TimeInterval
    public var usedHeadOnlyModel: Bool

    public init(
        point: CGPoint,
        displayUUID: String,
        confidence: Double,
        timestamp: TimeInterval,
        usedHeadOnlyModel: Bool
    ) {
        self.point = point
        self.displayUUID = displayUUID
        self.confidence = confidence
        self.timestamp = timestamp
        self.usedHeadOnlyModel = usedHeadOnlyModel
    }
}

public enum GazeObservation: Sendable, Equatable {
    case point(GazePoint)
    case offScreen
    case noFace
    case uncalibrated
}
