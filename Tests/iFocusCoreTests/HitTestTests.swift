import CoreGraphics
import Testing
@testable import iFocusCore

@Suite("HitTest")
struct HitTestTests {
    @Test("T15 hitTest returns each of five terminals at center")
    func t15FiveTerminalsCenter() {
        let config = Config()

        let deskSnap = WindowSnapshot(
            windows: Rig.deskThree.windows,
            frontmostPID: 1001,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: Rig.deskPortraitTopID,
            takenAt: 0
        )
        let deskTerminalIDs = [
            Rig.deskPortraitTopID,
            Rig.deskPortraitBottomID,
            Rig.deskMainLeftID,
            Rig.deskMainRightID,
            Rig.deskBuiltinTermID,
        ]
        for wid in deskTerminalIDs {
            let win = deskSnap.window(id: wid)!
            let center = CGPoint(x: win.bounds.midX, y: win.bounds.midY)
            #expect(WindowHitTester.hitTest(center, in: deskSnap, config: config) == .window(win))
        }

        let dualSnap = WindowSnapshot(
            windows: Rig.dualExternal.windows,
            frontmostPID: 1001,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: Rig.dualLeftTopID,
            takenAt: 0
        )
        for win in Rig.dualExternal.windows {
            let center = CGPoint(x: win.bounds.midX, y: win.bounds.midY)
            #expect(WindowHitTester.hitTest(center, in: dualSnap, config: config) == .window(win))
        }
    }

    @Test("T16 occluding browser returns blocked")
    func t16OccludingBrowserBlocked() {
        let snap = WindowSnapshot(
            windows: Rig.deskThree.windows,
            frontmostPID: 1001,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: Rig.deskPortraitTopID,
            takenAt: 0
        )
        // (200, 200) is inside Safari browser (40,60,480,480) which is z=1 in front of mainLeft (z=3)
        let hit = WindowHitTester.hitTest(CGPoint(x: 200, y: 200), in: snap, config: Config.v1Mechanics)
        #expect(hit == .blocked)
    }

    @Test("T17 snap radius occlusion and blocklist precedence")
    func t17SnapOcclusionAndBlocklist() {
        var config = Config()
        config.snapRadiusPoints = 80

        let term = WindowDescriptor(
            windowID: 1,
            pid: 100,
            bundleID: "com.apple.Terminal",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            zIndex: 1
        )
        let occluder = WindowDescriptor(
            windowID: 2,
            pid: 200,
            bundleID: "com.apple.Safari",
            bounds: CGRect(x: 450, y: 100, width: 60, height: 300),
            zIndex: 0
        )
        let blockedBundleWin = WindowDescriptor(
            windowID: 3,
            pid: 300,
            bundleID: "com.apple.systempreferences",
            bounds: CGRect(x: 700, y: 100, width: 400, height: 300),
            zIndex: 2
        )

        // Snap inside 80 pt radius on uncovered left side (x=50, 50 pt left of x=100)
        let uncoveredSnap = WindowSnapshot(windows: [term], frontmostPID: 100, frontmostBundleID: "com.apple.Terminal", focusedWindowID: 1, takenAt: 0)
        #expect(WindowHitTester.hitTest(CGPoint(x: 50, y: 200), in: uncoveredSnap, config: config) == .window(term))
        // Outside 80 pt radius (x=10, 90 pt away)
        #expect(WindowHitTester.hitTest(CGPoint(x: 10, y: 200), in: uncoveredSnap, config: config) == .none)

        // Nearest point covered by front occluder -> snap refused
        let occludedSnap = WindowSnapshot(windows: [occluder, term], frontmostPID: 100, frontmostBundleID: "com.apple.Terminal", focusedWindowID: 1, takenAt: 0)
        #expect(WindowHitTester.hitTest(CGPoint(x: 540, y: 200), in: occludedSnap, config: config) == .none)

        // Hard blocklist overrides allowedBundleIDs
        var permissiveConfig = config
        permissiveConfig.allowedBundleIDs.append("com.apple.systempreferences")
        let blocklistSnap = WindowSnapshot(windows: [blockedBundleWin], frontmostPID: 100, frontmostBundleID: "com.apple.Terminal", focusedWindowID: nil, takenAt: 0)
        #expect(WindowHitTester.hitTest(CGPoint(x: 800, y: 200), in: blocklistSnap, config: permissiveConfig) == .blocked)
    }

    @Test("T18 identical frame twin returns frontmost only")
    func t18IdenticalFrameTwin() {
        let snap = WindowSnapshot(
            windows: Rig.deskThree.windows,
            frontmostPID: 1001,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: Rig.deskPortraitTopID,
            takenAt: 0
        )
        let front = snap.window(id: Rig.deskMainRightID)!
        let center = CGPoint(x: front.bounds.midX, y: front.bounds.midY)
        let hit = WindowHitTester.hitTest(center, in: snap, config: Config())
        #expect(hit == .window(front))
        if case .window(let w) = hit {
            #expect(w.windowID == Rig.deskMainRightID)
            #expect(w.windowID != Rig.deskMainRightTwinID)
        }
    }

    @Test("T60 WindowClassifier handles W1 fixtures W2 prompt aliases and empty displayBounds")
    func t60WindowClassifierTable() {
        let ownPID: Int32 = 4242
        let otherPID: Int32 = 5000
        let displayBounds = [CGRect(x: 0, y: 0, width: 1496, height: 967)]

        // W1 rows
        #expect(WindowClassifier.classify(
            layer: 2001, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: "com.apple.loginwindow",
            bounds: CGRect(x: -15000, y: -15000, width: 30000, height: 30000),
            displayBounds: displayBounds
        ) == .securityPrompt)

        #expect(WindowClassifier.classify(
            layer: 2004, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: "com.apple.loginwindow",
            bounds: CGRect(x: 0, y: 0, width: 1496, height: 967),
            displayBounds: displayBounds
        ) == .securityPrompt)

        #expect(WindowClassifier.classify(
            layer: 2147483646, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: nil,
            bounds: CGRect(x: 0, y: 0, width: 1496, height: 967),
            displayBounds: displayBounds
        ) == .ignored)

        #expect(WindowClassifier.classify(
            layer: 24, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: nil,
            bounds: CGRect(x: 0, y: 0, width: 1496, height: 29),
            displayBounds: displayBounds
        ) == .ignored)

        for width in [30.0, 154.0] {
            #expect(WindowClassifier.classify(
                layer: 25, alpha: 1.0, pid: otherPID, ownPID: ownPID,
                bundleID: "com.apple.controlcenter",
                bounds: CGRect(x: 1100, y: 0, width: width, height: 29),
                displayBounds: displayBounds
            ) == .ignored)
        }

        #expect(WindowClassifier.classify(
            layer: 20, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: "com.apple.dock",
            bounds: CGRect(x: 0, y: 0, width: 1496, height: 967),
            displayBounds: displayBounds
        ) == .ignored)

        #expect(WindowClassifier.classify(
            layer: 8, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: "com.example.AmbientOverlay",
            bounds: CGRect(x: 0, y: 0, width: 1496, height: 967),
            displayBounds: displayBounds
        ) == .ignored)

        #expect(WindowClassifier.classify(
            layer: 8, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: "com.example.ModalPanel",
            bounds: CGRect(x: 200, y: 200, width: 400, height: 300),
            displayBounds: displayBounds
        ) == .occluder)

        #expect(WindowClassifier.classify(
            layer: 8, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: nil,
            bounds: CGRect(x: 200, y: 200, width: 400, height: 300),
            displayBounds: displayBounds
        ) == .occluder)

        #expect(WindowClassifier.classify(
            layer: 0, alpha: 1.0, pid: ownPID, ownPID: ownPID,
            bundleID: "dev.ifocus.app",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            displayBounds: displayBounds
        ) == .ignored)

        // AR1 + W2 canonicalBundleID fallback
        let secID = WindowClassifier.canonicalBundleID(bundleID: nil, ownerName: "SecurityAgent")
        #expect(secID == "com.apple.SecurityAgent")
        #expect(WindowClassifier.classify(
            layer: 8, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: secID,
            bounds: CGRect(x: 300, y: 200, width: 420, height: 220),
            displayBounds: displayBounds
        ) == .securityPrompt)

        let authID = WindowClassifier.canonicalBundleID(bundleID: nil, ownerName: "coreautha")
        #expect(authID == "com.apple.LocalAuthentication.UIAgent")
        #expect(WindowClassifier.classify(
            layer: 8, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: authID,
            bounds: CGRect(x: 300, y: 200, width: 380, height: 200),
            displayBounds: displayBounds
        ) == .securityPrompt)

        #expect(WindowClassifier.canonicalBundleID(bundleID: nil, ownerName: "UnknownProcess") == nil)

        // Empty displayBounds falls back to occluder for full-display third-party overlay
        #expect(WindowClassifier.classify(
            layer: 8, alpha: 1.0, pid: otherPID, ownPID: ownPID,
            bundleID: "com.example.AmbientOverlay",
            bounds: CGRect(x: 0, y: 0, width: 1496, height: 967),
            displayBounds: []
        ) == .occluder)
    }

    @Test("T61 layer above zero occludes terminal and is ineligible even when allowlisted")
    func t61LayerAboveZeroOccludesAndIsIneligible() {
        let config = Config()
        let dialog = WindowDescriptor(
            windowID: 50,
            pid: 200,
            bundleID: "com.apple.SecurityAgent",
            bounds: CGRect(x: 200, y: 200, width: 400, height: 300),
            zIndex: 0,
            layer: 8
        )
        let term = WindowDescriptor(
            windowID: 51,
            pid: 100,
            bundleID: "com.mitchellh.ghostty",
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            zIndex: 1,
            layer: 0
        )
        let snapDialogOverTerm = WindowSnapshot(
            windows: [dialog, term],
            frontmostPID: 100,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: 51,
            takenAt: 0
        )
        #expect(WindowHitTester.hitTest(CGPoint(x: 350, y: 350), in: snapDialogOverTerm, config: config) == .blocked)

        let allowlistedLayer3 = WindowDescriptor(
            windowID: 52,
            pid: 100,
            bundleID: "com.mitchellh.ghostty",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            zIndex: 0,
            layer: 3
        )
        let snapLayer3 = WindowSnapshot(
            windows: [allowlistedLayer3],
            frontmostPID: 100,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: nil,
            takenAt: 0
        )
        #expect(WindowHitTester.hitTest(CGPoint(x: 250, y: 250), in: snapLayer3, config: config) == .blocked)
    }

    @Test("T76 gap snap rejected when ineligible large window lies strictly closer")
    func t76GapSnapRejectedByCloserIneligibleWindow() {
        var config = Config.v1Mechanics
        config.snapRadiusPoints = 80

        let safari = WindowDescriptor(
            windowID: 1,
            pid: 200,
            bundleID: "com.apple.Safari",
            bounds: CGRect(x: 100, y: 100, width: 600, height: 400),
            zIndex: 0,
            layer: 0
        )
        let term = WindowDescriptor(
            windowID: 2,
            pid: 100,
            bundleID: "com.mitchellh.ghostty",
            bounds: CGRect(x: 765, y: 100, width: 400, height: 400),
            zIndex: 1,
            layer: 0
        )
        let gapPoint = CGPoint(x: 705, y: 300) // 5 pt from Safari, 60 pt from Ghostty

        let snapWithSafari = WindowSnapshot(
            windows: [safari, term],
            frontmostPID: 100,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: 2,
            takenAt: 0
        )
        #expect(WindowHitTester.hitTest(gapPoint, in: snapWithSafari, config: config) == .none)

        let snapWithoutSafari = WindowSnapshot(
            windows: [term],
            frontmostPID: 100,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: 2,
            takenAt: 0
        )
        #expect(WindowHitTester.hitTest(gapPoint, in: snapWithoutSafari, config: config) == .window(term))
    }

    @Test("T84 eligibility across allApps blocklist prefixes nil empty excluded layer and allowlist")
    func t84AllAppsVsAllowlistEligibilityTable() {
        let allAppsConfig = Config(excludedBundleIDs: ["com.example.ExcludedApp"])
        let rect = CGRect(x: 100, y: 100, width: 800, height: 600)

        func makeWindow(bundleID: String?, bounds: CGRect = rect, layer: Int = 0) -> WindowDescriptor {
            WindowDescriptor(windowID: 1, pid: 100, bundleID: bundleID, bounds: bounds, zIndex: 0, layer: layer)
        }

        // Allowed in allApps
        for id in ["com.google.Chrome", "com.spotify.client", "com.mitchellh.ghostty", "com.microsoft.VSCode", "com.apple.finder"] {
            #expect(WindowHitTester.isEligible(makeWindow(bundleID: id), config: allAppsConfig) == true)
        }

        // Every hardBlocklist entry and each hardBlockPrefix family is ineligible
        for blocked in Config.hardBlocklist {
            #expect(WindowHitTester.isEligible(makeWindow(bundleID: blocked), config: allAppsConfig) == false)
        }
        for prefixed in ["com.1password.safari", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords.Helper"] {
            #expect(WindowHitTester.isEligible(makeWindow(bundleID: prefixed), config: allAppsConfig) == false)
        }

        // Nil, empty, excluded, layer > 0, and sub-minimum bounds are ineligible
        #expect(WindowHitTester.isEligible(makeWindow(bundleID: nil), config: allAppsConfig) == false)
        #expect(WindowHitTester.isEligible(makeWindow(bundleID: ""), config: allAppsConfig) == false)
        #expect(WindowHitTester.isEligible(makeWindow(bundleID: "com.example.ExcludedApp"), config: allAppsConfig) == false)
        #expect(WindowHitTester.isEligible(makeWindow(bundleID: "com.mitchellh.ghostty", layer: 3), config: allAppsConfig) == false)
        #expect(WindowHitTester.isEligible(makeWindow(bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: 0, y: 0, width: 100, height: 60)), config: allAppsConfig) == false)

        // Allowlist scope restricts to allowedBundleIDs
        let allowlistConfig = Config(focusScope: .allowlist)
        #expect(WindowHitTester.isEligible(makeWindow(bundleID: "com.apple.Safari"), config: allowlistConfig) == false)
        #expect(WindowHitTester.isEligible(makeWindow(bundleID: "com.mitchellh.ghostty"), config: allowlistConfig) == true)
    }
}
