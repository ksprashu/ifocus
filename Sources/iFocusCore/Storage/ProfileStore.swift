import Foundation

public struct ProfileLoadResult: Sendable, Equatable {
    public var profile: CalibrationProfile?
    public var error: String?
    public var filePresent: Bool

    public init(profile: CalibrationProfile?, error: String? = nil, filePresent: Bool = false) {
        self.profile = profile
        self.error = error
        self.filePresent = filePresent
    }
}

public struct ProfileStore: Sendable {
    public static let filename = "calibration.json"

    public let fileStore: SecureFileStore

    public init(fileStore: SecureFileStore = SecureFileStore()) {
        self.fileStore = fileStore
    }

    public func load(activeCameraUniqueID: String? = nil) -> ProfileLoadResult {
        do {
            guard let data = try fileStore.read(Self.filename) else {
                return ProfileLoadResult(profile: nil, error: nil, filePresent: false)
            }
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(CalibrationProfile.self, from: data)
            if let validationError = decoded.validate(activeCameraUniqueID: activeCameraUniqueID) {
                return ProfileLoadResult(
                    profile: nil,
                    error: validationError.description,
                    filePresent: true
                )
            }
            return ProfileLoadResult(profile: decoded, error: nil, filePresent: true)
        } catch {
            return ProfileLoadResult(
                profile: nil,
                error: "Failed to load \(Self.filename): \(error)",
                filePresent: true
            )
        }
    }

    public func save(_ profile: CalibrationProfile) throws {
        if let validationError = profile.validate() {
            throw validationError
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        try fileStore.write(data, to: Self.filename)
    }
}
