import Foundation

public struct ConfigLoadResult: Sendable, Equatable {
    public var config: Config
    public var error: String?
    public var filePresent: Bool

    public init(config: Config, error: String? = nil, filePresent: Bool = false) {
        self.config = config
        self.error = error
        self.filePresent = filePresent
    }
}

public struct ConfigStore: Sendable {
    public static let filename = "config.json"

    public let fileStore: SecureFileStore

    public init(fileStore: SecureFileStore = SecureFileStore()) {
        self.fileStore = fileStore
    }

    public func load() -> ConfigLoadResult {
        do {
            guard let data = try fileStore.read(Self.filename) else {
                return ConfigLoadResult(config: Config(), error: nil, filePresent: false)
            }
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(Config.self, from: data)
            return ConfigLoadResult(config: decoded.clamped(), error: nil, filePresent: true)
        } catch {
            return ConfigLoadResult(
                config: Config(),
                error: "Failed to load \(Self.filename): \(error)",
                filePresent: true
            )
        }
    }

    public func save(_ config: Config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config.clamped())
        try fileStore.write(data, to: Self.filename)
    }
}
