import Foundation

public enum ProfileValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case nonFiniteValue
    case emptyModels
    case invalidArrayLength(displayUUID: String, field: String)
    case nonPositiveDeviation(displayUUID: String)
    case weightOutOfBounds(displayUUID: String, value: Double)
    case invalidCrossValidationError(displayUUID: String, value: Double)
    case invalidSampleCount(displayUUID: String, count: Int)
    case cameraMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let v):
            return "Unsupported calibration schemaVersion \(v)"
        case .nonFiniteValue:
            return "Calibration profile contains a non-finite number"
        case .emptyModels:
            return "Calibration profile contains no display models"
        case .invalidArrayLength(let uuid, let field):
            return "Display \(uuid) has invalid \(field) length"
        case .nonPositiveDeviation(let uuid):
            return "Display \(uuid) has non-positive standard deviation"
        case .weightOutOfBounds(let uuid, let value):
            return "Display \(uuid) has weight \(value) exceeding magnitude 100"
        case .invalidCrossValidationError(let uuid, let value):
            return "Display \(uuid) has invalid cross-validation error \(value)"
        case .invalidSampleCount(let uuid, let count):
            return "Display \(uuid) has invalid sample count \(count)"
        case .cameraMismatch(let expected, let actual):
            return "Calibration camera '\(actual)' does not match active camera '\(expected)'"
        }
    }
}

public struct DisplayModel: Sendable, Equatable, Codable {
    public var featureMeans: [Double]       // [yaw, pitch, eyeX, eyeY]
    public var featureStds: [Double]        // [yaw, pitch, eyeX, eyeY]
    public var weightsU: [Double]           // [bias, yaw, pitch, eyeX, eyeY]
    public var weightsV: [Double]           // [bias, yaw, pitch, eyeX, eyeY]
    public var headOnlyWeightsU: [Double]   // [bias, yaw, pitch]
    public var headOnlyWeightsV: [Double]   // [bias, yaw, pitch]
    public var centroid: [Double]           // [yaw, pitch, eyeX, eyeY] in standardised units
    public var crossValidationError: Double
    public var sampleCount: Int
    public var headBarelyMoved: Bool

    public init(
        featureMeans: [Double],
        featureStds: [Double],
        weightsU: [Double],
        weightsV: [Double],
        headOnlyWeightsU: [Double],
        headOnlyWeightsV: [Double],
        centroid: [Double],
        crossValidationError: Double,
        sampleCount: Int,
        headBarelyMoved: Bool
    ) {
        self.featureMeans = featureMeans
        self.featureStds = featureStds
        self.weightsU = weightsU
        self.weightsV = weightsV
        self.headOnlyWeightsU = headOnlyWeightsU
        self.headOnlyWeightsV = headOnlyWeightsV
        self.centroid = centroid
        self.crossValidationError = crossValidationError
        self.sampleCount = sampleCount
        self.headBarelyMoved = headBarelyMoved
    }

    public func validate(displayUUID: String) -> ProfileValidationError? {
        guard featureMeans.count == 4 else { return .invalidArrayLength(displayUUID: displayUUID, field: "featureMeans") }
        guard featureStds.count == 4 else { return .invalidArrayLength(displayUUID: displayUUID, field: "featureStds") }
        guard weightsU.count == 5 else { return .invalidArrayLength(displayUUID: displayUUID, field: "weightsU") }
        guard weightsV.count == 5 else { return .invalidArrayLength(displayUUID: displayUUID, field: "weightsV") }
        guard headOnlyWeightsU.count == 3 else { return .invalidArrayLength(displayUUID: displayUUID, field: "headOnlyWeightsU") }
        guard headOnlyWeightsV.count == 3 else { return .invalidArrayLength(displayUUID: displayUUID, field: "headOnlyWeightsV") }
        guard centroid.count == 4 else { return .invalidArrayLength(displayUUID: displayUUID, field: "centroid") }

        let allNumbers = featureMeans + featureStds + weightsU + weightsV + headOnlyWeightsU + headOnlyWeightsV + centroid
        if allNumbers.contains(where: { !$0.isFinite }) {
            return .nonFiniteValue
        }
        if featureStds.contains(where: { $0 <= 0 }) {
            return .nonPositiveDeviation(displayUUID: displayUUID)
        }
        for w in weightsU + weightsV + headOnlyWeightsU + headOnlyWeightsV {
            if abs(w) > 100.0 {
                return .weightOutOfBounds(displayUUID: displayUUID, value: w)
            }
        }
        guard crossValidationError.isFinite, crossValidationError >= 0, crossValidationError <= 0.20 else {
            return .invalidCrossValidationError(displayUUID: displayUUID, value: crossValidationError)
        }
        guard sampleCount > 0 else {
            return .invalidSampleCount(displayUUID: displayUUID, count: sampleCount)
        }
        return nil
    }
}

public struct CalibrationProfile: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var cameraUniqueID: String
    public var createdAt: TimeInterval
    public var models: [String: DisplayModel]
    public var pitchDownLimit: Double?

    public init(
        schemaVersion: Int = CalibrationProfile.currentSchemaVersion,
        cameraUniqueID: String,
        createdAt: TimeInterval,
        models: [String: DisplayModel],
        pitchDownLimit: Double?
    ) {
        self.schemaVersion = schemaVersion
        self.cameraUniqueID = cameraUniqueID
        self.createdAt = createdAt
        self.models = models
        self.pitchDownLimit = pitchDownLimit
    }

    public func validate(activeCameraUniqueID: String? = nil) -> ProfileValidationError? {
        guard schemaVersion == Self.currentSchemaVersion else {
            return .unsupportedSchemaVersion(schemaVersion)
        }
        guard createdAt.isFinite else {
            return .nonFiniteValue
        }
        if let pitchDownLimit, !pitchDownLimit.isFinite {
            return .nonFiniteValue
        }
        guard !models.isEmpty else {
            return .emptyModels
        }
        for (uuid, model) in models {
            if let err = model.validate(displayUUID: uuid) {
                return err
            }
        }
        if let activeCameraUniqueID, activeCameraUniqueID != cameraUniqueID {
            return .cameraMismatch(expected: activeCameraUniqueID, actual: cameraUniqueID)
        }
        return nil
    }

    public func validated(activeCameraUniqueID: String? = nil) -> Result<CalibrationProfile, ProfileValidationError> {
        if let error = validate(activeCameraUniqueID: activeCameraUniqueID) {
            return .failure(error)
        }
        return .success(self)
    }
}
