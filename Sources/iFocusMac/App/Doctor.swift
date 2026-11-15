import Carbon.HIToolbox
import Foundation
import iFocusCore

public enum Doctor {
    public static func run(focusTest: Bool) async -> Int32 {
        let configStore = ConfigStore()
        var configResult = configStore.load()
        configResult.config.excludeBundleIDIfNeeded(Bundle.main.bundleIdentifier)
        let config = configResult.config

        let hasUsageDesc = Permissions.hasCameraUsageDescription()
        let cameraStatus = Permissions.cameraStatus()
        let axTrusted = Permissions.isAccessibilityTrusted()
        let resolverMode = AXWindowID.mode(usePrivateResolver: config.usePrivateWindowIDResolver)
        let secureInput = IsSecureEventInputEnabled()
        let liveInput = SystemInputActivityProvider().sample()

        print("iFocus Doctor Report")
        print("====================")
        print("NSCameraUsageDescription: \(hasUsageDesc ? "present" : "missing")")
        print("Camera permission:        \(cameraStatus.rawValue)")
        print("Accessibility permission: \(axTrusted ? "trusted" : "not trusted")")
        print("Window-ID resolver mode:  \(resolverMode.rawValue)")
        print("Secure Input active:      \(secureInput ? "yes" : "no")")
        if secureInput || config.respectSecureInput {
            print("  Note: Always-on Secure Keyboard Entry in a terminal freezes iFocus switching unless respectSecureInput is false in config.json.")
        }
        print(
            String(
                format: "Live input sample:        key=%.2fs click=%.2fs move=%.2fs modifierHeld=%@ buttonHeld=%@",
                liveInput.secondsSinceKeyboard,
                liveInput.secondsSincePointerClick,
                liveInput.secondsSincePointerMove,
                liveInput.isModifierHeld ? "yes" : "no",
                liveInput.isPointerButtonDown ? "yes" : "no"
            )
        )

        print("\nConfiguration (\(SecureFileStore.defaultDirectoryURL().appendingPathComponent(ConfigStore.filename).path)):")
        if let cfgErr = configResult.error {
            print("  Status: INVALID (\(cfgErr)); using defaults")
        } else if configResult.filePresent {
            print("  Status: valid")
        } else {
            print("  Status: using defaults (no config.json)")
        }
        print("  Focus scope: \(config.focusScope.rawValue)")
        print("  Dwell (cross / same): \(config.dwellCrossDisplaySeconds)s / \(config.dwellSameDisplaySeconds)s, quiet (key / move / click): \(config.typingLockSeconds)s / \(config.pointerMoveLockSeconds)s / \(config.pointerClickLockSeconds)s, stickyMargin: \(config.stickyMarginPoints)pt, cameraFPS: \(config.cameraFPS)")
        if config.focusScope == .allowlist {
            print("  Allowed bundle IDs: \(config.allowedBundleIDs.joined(separator: ", "))")
        }
        if !config.excludedBundleIDs.isEmpty {
            print("  Excluded bundle IDs: \(config.excludedBundleIDs.joined(separator: ", "))")
        }

        let topology = CGDisplayTopologyService.readCurrentSync()
        print("\nDisplays:")
        if topology.displays.isEmpty {
            print("  no active displays")
        } else {
            for d in topology.displays {
                let ptPerMMX = d.physicalSizeMM.width > 0 ? String(format: "%.2f", Double(d.bounds.width / d.physicalSizeMM.width)) : "n/a"
                print("  - \(d.uuid) (id=\(d.id)\(d.isMain ? ", main" : "")\(d.isBuiltin ? ", builtin" : "")): bounds=(\(Int(d.bounds.origin.x)), \(Int(d.bounds.origin.y)), \(Int(d.bounds.width)), \(Int(d.bounds.height))), sizeMM=(\(Int(d.physicalSizeMM.width))x\(Int(d.physicalSizeMM.height))), \(ptPerMMX) pt/mm")
            }
        }

        let devices = CameraSession.availableDevices()
        print("\nCameras:")
        if devices.isEmpty {
            print("  none detected")
        } else {
            for dev in devices {
                print("  - \(dev.localizedName) [id=\(dev.uniqueID)]\(dev.isDefault ? " (default)" : "")")
            }
        }

        let activeCameraID = config.cameraUniqueID ?? devices.first(where: \.isDefault)?.uniqueID ?? devices.first?.uniqueID
        let profileStore = ProfileStore()
        let profileResult = profileStore.load(activeCameraUniqueID: activeCameraID)
        print("\nCalibration (\(SecureFileStore.defaultDirectoryURL().appendingPathComponent(ProfileStore.filename).path)):")
        if let prof = profileResult.profile {
            print("  Status: valid (camera=\(prof.cameraUniqueID), models=\(prof.models.count), pitchDownLimit=\(prof.pitchDownLimit.map { String(format: "%.3f", $0) } ?? "nil"))")
            for (uuid, model) in prof.models.sorted(by: { $0.key < $1.key }) {
                let headWarn = model.headBarelyMoved ? " [WARNING: headBarelyMoved]" : ""
                print("  - \(uuid): cvRMS=\(String(format: "%.4f", model.crossValidationError)), samples=\(model.sampleCount)\(headWarn)")
            }
        } else if let err = profileResult.error {
            print("  Status: invalid (\(err))")
        } else {
            print("  Status: not calibrated")
        }

        let catalog = CGWindowCatalogService()
        let (snapshot, inspections) = await catalog.detailedSnapshot()
        let actuator = AXActuator(usePrivateWindowIDResolver: config.usePrivateWindowIDResolver)
        let eligible = snapshot.windows.filter { WindowHitTester.isEligible($0, config: config) }

        print("\nOn-Screen Windows (\(snapshot.windows.count) kept, \(eligible.count) eligible):")
        var axCache: [Int32: [AXWindowCandidate]] = [:]
        for win in snapshot.windows {
            let isEligible = WindowHitTester.isEligible(win, config: config)
            let statusDesc: String
            if isEligible {
                let matchSummary: String
                if axTrusted {
                    let candidates: [AXWindowCandidate]
                    if let cached = axCache[win.pid] {
                        candidates = cached
                    } else {
                        let fetched = await actuator.windows(of: win.pid)
                        axCache[win.pid] = fetched
                        candidates = fetched
                    }
                    matchSummary = describeAXMatch(AXWindowMatcher.match(target: win, candidates: candidates))
                } else {
                    matchSummary = "skipped (not trusted)"
                }
                statusDesc = "eligible=yes axMatch=\(matchSummary)"
            } else {
                let reason = ineligibilityReason(win, config: config)
                statusDesc = "eligible=no (\(reason))"
            }
            let focusedTag = (win.windowID == snapshot.focusedWindowID) ? " [focused]" : ""
            print("  - id=\(win.windowID) pid=\(win.pid) bundle=\(win.bundleID ?? "unknown") layer=\(win.layer) bounds=(\(Int(win.bounds.origin.x)), \(Int(win.bounds.origin.y)), \(Int(win.bounds.width)), \(Int(win.bounds.height))) z=\(win.zIndex) \(statusDesc)\(focusedTag)")
        }

        let occludersAndPrompts = inspections.filter { $0.role == .occluder || $0.role == .securityPrompt }
        let promptVetoActive = WindowHitTester.securityPromptVisible(in: snapshot)
        print("\nOccluders & Security Prompts (\(occludersAndPrompts.count), prompt veto active: \(promptVetoActive ? "yes" : "no")):")
        for item in occludersAndPrompts {
            let w = item.descriptor
            let fallbackTag = item.usedOwnerNameFallback ? " [ownerName-fallback]" : ""
            let roleTag = item.role == .securityPrompt ? "securityPrompt" : "occluder"
            print("  - [\(roleTag)] id=\(w.windowID) pid=\(w.pid) owner=\(w.bundleID ?? item.ownerName ?? "unknown")\(fallbackTag) layer=\(w.layer) bounds=(\(Int(w.bounds.origin.x)), \(Int(w.bounds.origin.y)), \(Int(w.bounds.width)), \(Int(w.bounds.height)))")
        }

        guard focusTest else {
            return 0
        }

        print("\nFocus Test:")
        guard axTrusted else {
            print("  ERROR: Accessibility permission is required for --focus-test.")
            return 77
        }
        guard !eligible.isEmpty else {
            print("  No eligible windows found to cycle.")
            return 0
        }

        let focusTargets = selectFocusTestTargets(from: eligible, limit: 6)
        let switcher = TrustedFocusSwitcher(
            ladder: LadderFocusSwitcher(
                actuator: actuator,
                catalog: catalog,
                sleeper: SystemSleeper(),
                clock: SystemClock()
            )
        )
        let originalFocusedID = snapshot.focusedWindowID
        var allSucceeded = true

        for win in focusTargets {
            let outcome = await switcher.focus(win)
            print("  - target id=\(win.windowID) (\(win.bundleID ?? "unknown")): \(describeOutcome(outcome))")
            if case .failed = outcome {
                allSucceeded = false
            }
        }

        if let origID = originalFocusedID, let origWin = snapshot.window(id: origID) {
            let restoreOutcome = await switcher.focus(origWin)
            print("  - restore original id=\(origID): \(describeOutcome(restoreOutcome))")
        }

        return allSucceeded ? 0 : 1
    }

    private static func ineligibilityReason(_ window: WindowDescriptor, config: Config) -> String {
        if window.layer != 0 {
            return "layer=\(window.layer)"
        }
        if window.bounds.width < 120 || window.bounds.height < 80 {
            return "too-small"
        }
        guard let bundleID = window.bundleID, !bundleID.isEmpty else {
            return "missing-bundle-id"
        }
        if Config.isHardBlocked(bundleID) {
            return "hard-blocked"
        }
        if config.excludedBundleIDs.contains(bundleID) {
            return "excluded"
        }
        if config.focusScope == .allowlist && !config.allowedBundleIDs.contains(bundleID) {
            return "not-in-allowlist"
        }
        return "ineligible"
    }

    private static func selectFocusTestTargets(from eligible: [WindowDescriptor], limit: Int) -> [WindowDescriptor] {
        var selected: [WindowDescriptor] = []
        var usedIDs: Set<UInt32> = []
        var seenPIDs: Set<Int32> = []

        for win in eligible where !seenPIDs.contains(win.pid) {
            selected.append(win)
            usedIDs.insert(win.windowID)
            seenPIDs.insert(win.pid)
            if selected.count >= limit { return selected }
        }
        for win in eligible where !usedIDs.contains(win.windowID) {
            selected.append(win)
            if selected.count >= limit { break }
        }
        return selected
    }

    private static func describeAXMatch(_ match: AXMatch) -> String {
        switch match {
        case .exact(let idx):
            return "exact(index=\(idx))"
        case .geometric(let idx):
            return "geometric(index=\(idx))"
        case .ambiguous(let idx, let count):
            return "ambiguous(index=\(idx), count=\(count))"
        case .approximate(let idx):
            return "approximate(index=\(idx))"
        case .notFound:
            return "notFound"
        }
    }

    private static func describeOutcome(_ outcome: FocusOutcome) -> String {
        switch outcome {
        case .switched(let strategy):
            return "switched(\(strategy.rawValue))"
        case .alreadyFocused:
            return "alreadyFocused"
        case .failed(let failure):
            return "failed(\(failure.rawValue))"
        }
    }
}
