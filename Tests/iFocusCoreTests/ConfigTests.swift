import Foundation
import Testing
@testable import iFocusCore

@Suite("Config")
struct ConfigTests {
    @Test("T33 config clamping malformed fallback and unknown keys")
    func t33ClampingMalformedAndUnknownKeys() throws {
        let tmpTemplate = "/tmp/ifocus-t33-XXXXXX"
        var buf = Array(tmpTemplate.utf8CString)
        guard let dirCStr = mkdtemp(&buf) else {
            Issue.record("mkdtemp failed")
            return
        }
        let dirURL = URL(fileURLWithPath: String(cString: dirCStr), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }

        let fileStore = SecureFileStore(directoryURL: dirURL)
        let configStore = ConfigStore(fileStore: fileStore)

        // Out-of-range values clamp and unknown keys are ignored
        let jsonValid = """
        {
          "dwellCrossDisplaySeconds": 99.0,
          "dwellSameDisplaySeconds": 0.01,
          "stickyMarginPoints": -50,
          "cameraFPS": 120,
          "unknownExtraSetting": "ignored",
          "nestedUnknown": { "a": 1 }
        }
        """
        try fileStore.write(Data(jsonValid.utf8), to: ConfigStore.filename)
        let loaded = configStore.load()
        #expect(loaded.error == nil)
        #expect(loaded.filePresent == true)
        #expect(loaded.config.dwellCrossDisplaySeconds == 5.0)
        #expect(loaded.config.dwellSameDisplaySeconds == 0.15)
        #expect(loaded.config.stickyMarginPoints == 0)
        #expect(loaded.config.cameraFPS == 30)

        // Malformed JSON falls back to defaults with error surfaced and file untouched
        let brokenJSON = "{ not valid json !!!"
        try fileStore.write(Data(brokenJSON.utf8), to: ConfigStore.filename)
        let badResult = configStore.load()
        #expect(badResult.error != nil)
        #expect(badResult.filePresent == true)
        #expect(badResult.config == Config())
        let rawAfterLoad = try fileStore.read(ConfigStore.filename)
        #expect(String(data: rawAfterLoad ?? Data(), encoding: .utf8) == brokenJSON)
    }

    @Test("T52 config bundle ID validation and 64 limit")
    func t52BundleIDValidationAndCap() {
        var input = (1...75).map { "com.example.term\($0)" }
        input.insert("", at: 0)
        input.insert("bad bundle id", at: 1)
        input.insert("com.example/slash", at: 2)
        input.insert(String(repeating: "a", count: 256), at: 3)

        var cfg = Config()
        cfg.allowedBundleIDs = input
        let clamped = cfg.clamped()

        #expect(clamped.allowedBundleIDs.count == 64)
        #expect(!clamped.allowedBundleIDs.contains(""))
        #expect(!clamped.allowedBundleIDs.contains("bad bundle id"))
        #expect(!clamped.allowedBundleIDs.contains("com.example/slash"))
        #expect(!clamped.allowedBundleIDs.contains { $0.count > 255 })
        #expect(clamped.allowedBundleIDs.first == "com.example.term1")
        #expect(clamped.allowedBundleIDs.last == "com.example.term64")
    }

    @Test("T79 Wave 2 config defaults ranges focusScope fallback removed keys and excludedBundleIDs")
    func t79Wave2ConfigDefaultsAndFocusScope() throws {
        let defaults = Config()
        #expect(defaults.dwellCrossDisplaySeconds == 1.2)
        #expect(defaults.dwellSameDisplaySeconds == 1.5)
        #expect(defaults.typingLockSeconds == 2.5)
        #expect(defaults.pointerMoveLockSeconds == 2.0)
        #expect(defaults.pointerClickLockSeconds == 2.5)
        #expect(defaults.focusScope == .allApps)
        #expect(defaults.excludedBundleIDs.isEmpty)

        // Clamping lower and upper bounds
        let low = Config(
            dwellCrossDisplaySeconds: 0.01,
            dwellSameDisplaySeconds: 0.01,
            typingLockSeconds: 0.1,
            pointerMoveLockSeconds: -5.0,
            pointerClickLockSeconds: -5.0
        )
        #expect(low.dwellCrossDisplaySeconds == 0.15)
        #expect(low.dwellSameDisplaySeconds == 0.15)
        #expect(low.typingLockSeconds == 0.3)
        #expect(low.pointerMoveLockSeconds == 0.0)
        #expect(low.pointerClickLockSeconds == 0.0)

        let high = Config(
            dwellCrossDisplaySeconds: 99.0,
            dwellSameDisplaySeconds: 99.0,
            typingLockSeconds: 99.0,
            pointerMoveLockSeconds: 99.0,
            pointerClickLockSeconds: 99.0
        )
        #expect(high.dwellCrossDisplaySeconds == 5.0)
        #expect(high.dwellSameDisplaySeconds == 5.0)
        #expect(high.typingLockSeconds == 10.0)
        #expect(high.pointerMoveLockSeconds == 10.0)
        #expect(high.pointerClickLockSeconds == 10.0)

        // focusScope decoding + unknown string fallback to allowlist + legacy mismatch keys ignored
        let decoder = JSONDecoder()
        let decodedAll = try decoder.decode(Config.self, from: Data(#"{"focusScope":"allApps"}"#.utf8))
        #expect(decodedAll.focusScope == .allApps)
        let decodedAllow = try decoder.decode(Config.self, from: Data(#"{"focusScope":"allowlist"}"#.utf8))
        #expect(decodedAllow.focusScope == .allowlist)
        let decodedMissing = try decoder.decode(Config.self, from: Data(#"{}"#.utf8))
        #expect(decodedMissing.focusScope == .allApps)
        let decodedUnknown = try decoder.decode(Config.self, from: Data(#"{"focusScope":"customUnknown"}"#.utf8))
        #expect(decodedUnknown.focusScope == .allowlist)

        let tmpTemplate = "/tmp/ifocus-t79-XXXXXX"
        var buf = Array(tmpTemplate.utf8CString)
        guard let dirCStr = mkdtemp(&buf) else {
            Issue.record("mkdtemp failed")
            return
        }
        let dirURL = URL(fileURLWithPath: String(cString: dirCStr), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }
        let fileStore = SecureFileStore(directoryURL: dirURL)
        let configStore = ConfigStore(fileStore: fileStore)
        let legacyJSON = """
        {
          "mismatchAlert": true,
          "mismatchBeep": true,
          "mismatchAlertIntervalSeconds": 4.0,
          "dwellCrossDisplaySeconds": 1.4
        }
        """
        try fileStore.write(Data(legacyJSON.utf8), to: ConfigStore.filename)
        let legacyLoaded = configStore.load()
        #expect(legacyLoaded.error == nil)
        #expect(legacyLoaded.config.dwellCrossDisplaySeconds == 1.4)
        #expect(legacyLoaded.config.focusScope == .allApps)

        // excludedBundleIDs sanitized & capped at 64
        var exInput = (1...75).map { "com.example.app\($0)" }
        exInput.insert("", at: 0)
        exInput.insert("has space", at: 1)
        exInput.insert("bad/slash", at: 2)
        exInput.insert(String(repeating: "z", count: 256), at: 3)
        let exCfg = Config(excludedBundleIDs: exInput)
        #expect(exCfg.excludedBundleIDs.count == 64)
        #expect(!exCfg.excludedBundleIDs.contains(""))
        #expect(!exCfg.excludedBundleIDs.contains("has space"))
        #expect(exCfg.excludedBundleIDs.first == "com.example.app1")
        #expect(exCfg.excludedBundleIDs.last == "com.example.app64")
    }
}
