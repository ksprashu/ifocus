import Foundation

public enum FocusScope: String, Sendable, Equatable, Codable {
    case allApps
    case allowlist
}

public struct Config: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public static let defaultAllowedBundleIDs: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
    ]

    public static let hardBlocklist: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.ScreenSaver.Engine",
        "com.apple.coreservices.uiagent",
        "com.apple.systempreferences",
        // System Settings on macOS 26 uses com.apple.systempreferences; com.apple.Settings is kept per TRG-06.
        "com.apple.Settings",
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.ScreenSharing",
        "com.1password.1password",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.apple.Spotlight",
        "com.apple.systemuiserver",
        "dev.ifocus.app",
    ]

    public static let hardBlockPrefixes: [String] = [
        "com.1password.",
        "com.agilebits.onepassword",
        "com.bitwarden.",
        "com.apple.Passwords",
    ]

    public static let securityPromptBundleIDs: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.coreservices.uiagent",
    ]

    public static let promptOwnerNames: [String: String] = [
        "SecurityAgent": "com.apple.SecurityAgent",
        "coreautha": "com.apple.LocalAuthentication.UIAgent",
        "CoreAuthUI": "com.apple.LocalAuthentication.UIAgent",
        "UserNotificationCenter": "com.apple.UserNotificationCenter",
        "CoreServicesUIAgent": "com.apple.coreservices.uiagent",
        "loginwindow": "com.apple.loginwindow",
    ]

    public static let chromeBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
    ]

    public var schemaVersion: Int
    public var dwellCrossDisplaySeconds: Double
    public var dwellSameDisplaySeconds: Double
    public var stickyMarginPoints: Double
    public var snapRadiusPoints: Double
    public var candidateDropoutSeconds: Double
    public var switchCooldownSeconds: Double
    public var failureBackoffSeconds: Double
    public var typingLockSeconds: Double
    public var pointerMoveLockSeconds: Double
    public var pointerClickLockSeconds: Double
    public var minConfidence: Double
    public var staleSampleSeconds: Double
    public var eyeHoldSeconds: Double
    public var offscreenMarginMM: Double
    public var offscreenMarginBottomMM: Double
    public var lookDownGuard: Bool
    public var lookDownMarginRadians: Double
    public var focusScope: FocusScope
    public var allowedBundleIDs: [String]
    public var excludedBundleIDs: [String]
    public var requireAllowedSource: Bool
    public var respectSecureInput: Bool
    public var displayFallback: Bool
    public var switchFlash: Bool
    public var cameraFPS: Int
    public var cameraUniqueID: String?
    public var usePrivateWindowIDResolver: Bool
    public var pauseHotKey: String

    public init(
        schemaVersion: Int = Config.currentSchemaVersion,
        dwellCrossDisplaySeconds: Double = 1.2,
        dwellSameDisplaySeconds: Double = 1.5,
        stickyMarginPoints: Double = 48,
        snapRadiusPoints: Double = 80,
        candidateDropoutSeconds: Double = 0.12,
        switchCooldownSeconds: Double = 0.60,
        failureBackoffSeconds: Double = 2.0,
        typingLockSeconds: Double = 2.5,
        pointerMoveLockSeconds: Double = 2.0,
        pointerClickLockSeconds: Double = 2.5,
        minConfidence: Double = 0.50,
        staleSampleSeconds: Double = 0.30,
        eyeHoldSeconds: Double = 0.30,
        offscreenMarginMM: Double = 60,
        offscreenMarginBottomMM: Double = 20,
        lookDownGuard: Bool = true,
        lookDownMarginRadians: Double = 0.14,
        focusScope: FocusScope = .allApps,
        allowedBundleIDs: [String] = Config.defaultAllowedBundleIDs,
        excludedBundleIDs: [String] = [],
        requireAllowedSource: Bool = true,
        respectSecureInput: Bool = true,
        displayFallback: Bool = false,
        switchFlash: Bool = true,
        cameraFPS: Int = 20,
        cameraUniqueID: String? = nil,
        usePrivateWindowIDResolver: Bool = true,
        pauseHotKey: String = "ctrl+opt+cmd+f"
    ) {
        self.schemaVersion = schemaVersion
        self.dwellCrossDisplaySeconds = dwellCrossDisplaySeconds
        self.dwellSameDisplaySeconds = dwellSameDisplaySeconds
        self.stickyMarginPoints = stickyMarginPoints
        self.snapRadiusPoints = snapRadiusPoints
        self.candidateDropoutSeconds = candidateDropoutSeconds
        self.switchCooldownSeconds = switchCooldownSeconds
        self.failureBackoffSeconds = failureBackoffSeconds
        self.typingLockSeconds = typingLockSeconds
        self.pointerMoveLockSeconds = pointerMoveLockSeconds
        self.pointerClickLockSeconds = pointerClickLockSeconds
        self.minConfidence = minConfidence
        self.staleSampleSeconds = staleSampleSeconds
        self.eyeHoldSeconds = eyeHoldSeconds
        self.offscreenMarginMM = offscreenMarginMM
        self.offscreenMarginBottomMM = offscreenMarginBottomMM
        self.lookDownGuard = lookDownGuard
        self.lookDownMarginRadians = lookDownMarginRadians
        self.focusScope = focusScope
        self.allowedBundleIDs = allowedBundleIDs
        self.excludedBundleIDs = excludedBundleIDs
        self.requireAllowedSource = requireAllowedSource
        self.respectSecureInput = respectSecureInput
        self.displayFallback = displayFallback
        self.switchFlash = switchFlash
        self.cameraFPS = cameraFPS
        self.cameraUniqueID = cameraUniqueID
        self.usePrivateWindowIDResolver = usePrivateWindowIDResolver
        self.pauseHotKey = pauseHotKey
        self = self.clamped()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Config.currentSchemaVersion
        guard decodedVersion == Config.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported config schemaVersion \(decodedVersion)"
            )
        }
        self.schemaVersion = decodedVersion
        self.dwellCrossDisplaySeconds = try container.decodeIfPresent(Double.self, forKey: .dwellCrossDisplaySeconds) ?? defaults.dwellCrossDisplaySeconds
        self.dwellSameDisplaySeconds = try container.decodeIfPresent(Double.self, forKey: .dwellSameDisplaySeconds) ?? defaults.dwellSameDisplaySeconds
        self.stickyMarginPoints = try container.decodeIfPresent(Double.self, forKey: .stickyMarginPoints) ?? defaults.stickyMarginPoints
        self.snapRadiusPoints = try container.decodeIfPresent(Double.self, forKey: .snapRadiusPoints) ?? defaults.snapRadiusPoints
        self.candidateDropoutSeconds = try container.decodeIfPresent(Double.self, forKey: .candidateDropoutSeconds) ?? defaults.candidateDropoutSeconds
        self.switchCooldownSeconds = try container.decodeIfPresent(Double.self, forKey: .switchCooldownSeconds) ?? defaults.switchCooldownSeconds
        self.failureBackoffSeconds = try container.decodeIfPresent(Double.self, forKey: .failureBackoffSeconds) ?? defaults.failureBackoffSeconds
        self.typingLockSeconds = try container.decodeIfPresent(Double.self, forKey: .typingLockSeconds) ?? defaults.typingLockSeconds
        self.pointerMoveLockSeconds = try container.decodeIfPresent(Double.self, forKey: .pointerMoveLockSeconds) ?? defaults.pointerMoveLockSeconds
        self.pointerClickLockSeconds = try container.decodeIfPresent(Double.self, forKey: .pointerClickLockSeconds) ?? defaults.pointerClickLockSeconds
        self.minConfidence = try container.decodeIfPresent(Double.self, forKey: .minConfidence) ?? defaults.minConfidence
        self.staleSampleSeconds = try container.decodeIfPresent(Double.self, forKey: .staleSampleSeconds) ?? defaults.staleSampleSeconds
        self.eyeHoldSeconds = try container.decodeIfPresent(Double.self, forKey: .eyeHoldSeconds) ?? defaults.eyeHoldSeconds
        self.offscreenMarginMM = try container.decodeIfPresent(Double.self, forKey: .offscreenMarginMM) ?? defaults.offscreenMarginMM
        self.offscreenMarginBottomMM = try container.decodeIfPresent(Double.self, forKey: .offscreenMarginBottomMM) ?? defaults.offscreenMarginBottomMM
        self.lookDownGuard = try container.decodeIfPresent(Bool.self, forKey: .lookDownGuard) ?? defaults.lookDownGuard
        self.lookDownMarginRadians = try container.decodeIfPresent(Double.self, forKey: .lookDownMarginRadians) ?? defaults.lookDownMarginRadians
        if let rawScope = try container.decodeIfPresent(String.self, forKey: .focusScope) {
            self.focusScope = FocusScope(rawValue: rawScope) ?? .allowlist
        } else {
            self.focusScope = defaults.focusScope
        }
        self.allowedBundleIDs = try container.decodeIfPresent([String].self, forKey: .allowedBundleIDs) ?? defaults.allowedBundleIDs
        self.excludedBundleIDs = try container.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? defaults.excludedBundleIDs
        self.requireAllowedSource = try container.decodeIfPresent(Bool.self, forKey: .requireAllowedSource) ?? defaults.requireAllowedSource
        self.respectSecureInput = try container.decodeIfPresent(Bool.self, forKey: .respectSecureInput) ?? defaults.respectSecureInput
        self.displayFallback = try container.decodeIfPresent(Bool.self, forKey: .displayFallback) ?? defaults.displayFallback
        self.switchFlash = try container.decodeIfPresent(Bool.self, forKey: .switchFlash) ?? defaults.switchFlash
        self.cameraFPS = try container.decodeIfPresent(Int.self, forKey: .cameraFPS) ?? defaults.cameraFPS
        self.cameraUniqueID = try container.decodeIfPresent(String.self, forKey: .cameraUniqueID)
        self.usePrivateWindowIDResolver = try container.decodeIfPresent(Bool.self, forKey: .usePrivateWindowIDResolver) ?? defaults.usePrivateWindowIDResolver
        self.pauseHotKey = try container.decodeIfPresent(String.self, forKey: .pauseHotKey) ?? defaults.pauseHotKey
        self = self.clamped()
    }

    public func clamped() -> Config {
        var copy = self
        copy.schemaVersion = Config.currentSchemaVersion
        copy.dwellCrossDisplaySeconds = Self.clampDouble(dwellCrossDisplaySeconds, fallback: 1.2, range: 0.15...5.0)
        copy.dwellSameDisplaySeconds = Self.clampDouble(dwellSameDisplaySeconds, fallback: 1.5, range: 0.15...5.0)
        copy.stickyMarginPoints = Self.clampDouble(stickyMarginPoints, fallback: 48, range: 0...200)
        copy.snapRadiusPoints = Self.clampDouble(snapRadiusPoints, fallback: 80, range: 0...300)
        copy.candidateDropoutSeconds = Self.clampDouble(candidateDropoutSeconds, fallback: 0.12, range: 0.03...0.5)
        copy.switchCooldownSeconds = Self.clampDouble(switchCooldownSeconds, fallback: 0.60, range: 0.2...5.0)
        copy.failureBackoffSeconds = Self.clampDouble(failureBackoffSeconds, fallback: 2.0, range: 0.5...30.0)
        copy.typingLockSeconds = Self.clampDouble(typingLockSeconds, fallback: 2.5, range: 0.3...10.0)
        copy.pointerMoveLockSeconds = Self.clampDouble(pointerMoveLockSeconds, fallback: 2.0, range: 0...10.0)
        copy.pointerClickLockSeconds = Self.clampDouble(pointerClickLockSeconds, fallback: 2.5, range: 0...10.0)
        copy.minConfidence = Self.clampDouble(minConfidence, fallback: 0.50, range: 0.1...0.95)
        copy.staleSampleSeconds = Self.clampDouble(staleSampleSeconds, fallback: 0.30, range: 0.1...1.0)
        copy.eyeHoldSeconds = Self.clampDouble(eyeHoldSeconds, fallback: 0.30, range: 0...1.0)
        copy.offscreenMarginMM = Self.clampDouble(offscreenMarginMM, fallback: 60, range: 10...200)
        copy.offscreenMarginBottomMM = Self.clampDouble(offscreenMarginBottomMM, fallback: 20, range: 0...200)
        copy.lookDownMarginRadians = Self.clampDouble(lookDownMarginRadians, fallback: 0.14, range: 0.03...0.6)
        copy.cameraFPS = min(max(cameraFPS, 5), 30)
        copy.allowedBundleIDs = Self.sanitizeBundleIDs(allowedBundleIDs)
        copy.excludedBundleIDs = Self.sanitizeBundleIDs(excludedBundleIDs)
        if let id = copy.cameraUniqueID, id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.cameraUniqueID = nil
        }
        let trimmedHotKey = copy.pauseHotKey.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.pauseHotKey = trimmedHotKey.isEmpty ? "ctrl+opt+cmd+f" : trimmedHotKey
        return copy
    }

    public static func isHardBlocked(_ bundleID: String) -> Bool {
        if hardBlocklist.contains(bundleID) {
            return true
        }
        return hardBlockPrefixes.contains { bundleID.hasPrefix($0) }
    }

    public mutating func excludeBundleIDIfNeeded(_ bundleID: String?) {
        guard let bundleID,
              !bundleID.isEmpty,
              Self.isValidBundleID(bundleID),
              !Self.isHardBlocked(bundleID),
              !excludedBundleIDs.contains(bundleID) else {
            return
        }
        excludedBundleIDs.append(bundleID)
    }

    public static func isValidBundleID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty && bytes.count <= 255 else { return false }
        for b in bytes {
            let ok = (b >= 65 && b <= 90)   // A-Z
                || (b >= 97 && b <= 122)    // a-z
                || (b >= 48 && b <= 57)     // 0-9
                || b == 46                  // .
                || b == 95                  // _
                || b == 45                  // -
            if !ok { return false }
        }
        return true
    }

    public static func sanitizeBundleIDs(_ ids: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for id in ids {
            guard isValidBundleID(id), !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(id)
            if result.count == 64 { break }
        }
        return result
    }

    public func isBundleAllowed(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        guard !Self.isHardBlocked(bundleID) else { return false }
        guard !excludedBundleIDs.contains(bundleID) else { return false }
        switch focusScope {
        case .allApps:
            return true
        case .allowlist:
            return allowedBundleIDs.contains(bundleID)
        }
    }

    private static func clampDouble(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
