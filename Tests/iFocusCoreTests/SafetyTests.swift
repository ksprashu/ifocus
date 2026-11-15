import CoreGraphics
import Foundation
import Testing
@testable import iFocusCore

@Suite("Safety")
struct SafetyTests {
    private static func validContext(now: TimeInterval = 10.0) -> SafetyContext {
        SafetyContext(
            now: now,
            isPaused: false,
            isSessionActive: true,
            input: InputActivity(),
            gaze: .point(GazePoint(
                point: CGPoint(x: 4000, y: 500),
                displayUUID: "disp-right",
                confidence: 0.95,
                timestamp: now,
                usedHeadOnlyModel: false
            )),
            faceCount: 1,
            headPitch: 0.0,
            pitchDownLimit: 0.30,
            frontmostBundleID: "com.mitchellh.ghostty",
            lastSwitchAt: nil,
            lastFailureAt: nil,
            config: Config()
        )
    }

    @Test("T26 all fourteen vetoes precedence and dispositions")
    func t26FourteenVetoesPrecedenceAndDispositions() {
        let policy = DefaultSafetyGuardPolicy()
        #expect(SafetyVeto.allCases.count == 14)

        let expectedDispositions: [SafetyVeto: VetoDisposition] = [
            .paused: .clear,
            .sessionInactive: .clear,
            .secureInput: .clear,
            .uncalibrated: .clear,
            .noGaze: .dropout,
            .staleGaze: .dropout,
            .lowConfidence: .dropout,
            .multipleFaces: .dropout,
            .lookingDown: .dropout,
            .sourceNotAllowed: .clear,
            .pointerActive: .clear,
            .failureBackoff: .clear,
            .typing: .clear,
            .cooldown: .hold,
        ]
        for veto in SafetyVeto.allCases {
            #expect(veto.disposition == expectedDispositions[veto])
        }

        // Verify each veto fires alone in exact precedence order
        func makeFailing(_ veto: SafetyVeto) -> (inout SafetyContext) -> Void {
            switch veto {
            case .paused: return { $0.isPaused = true }
            case .sessionInactive: return { $0.isSessionActive = false }
            case .secureInput: return { $0.input.isSecureInputEnabled = true }
            case .uncalibrated: return { $0.gaze = .uncalibrated }
            case .noGaze: return { $0.gaze = .offScreen }
            case .staleGaze: return { $0.gaze = .point(GazePoint(point: .zero, displayUUID: "d", confidence: 0.95, timestamp: 9.0, usedHeadOnlyModel: false)) }
            case .lowConfidence: return { $0.gaze = .point(GazePoint(point: .zero, displayUUID: "d", confidence: 0.2, timestamp: 10.0, usedHeadOnlyModel: false)) }
            case .multipleFaces: return { $0.faceCount = 2 }
            case .lookingDown: return { $0.headPitch = 0.60 }
            case .sourceNotAllowed: return { $0.frontmostBundleID = "com.apple.systempreferences" }
            case .pointerActive: return { $0.input.secondsSincePointerMove = 0.1 }
            case .failureBackoff: return { $0.lastFailureAt = 9.5 }
            case .typing: return { $0.input.secondsSinceKeyboard = 0.2 }
            case .cooldown: return { $0.lastSwitchAt = 9.8 }
            }
        }

        #expect(policy.evaluate(Self.validContext()) == .allow)

        let ordered: [SafetyVeto] = [
            .paused, .sessionInactive, .secureInput, .uncalibrated, .noGaze, .staleGaze,
            .lowConfidence, .multipleFaces, .lookingDown, .sourceNotAllowed, .pointerActive,
            .failureBackoff, .typing, .cooldown,
        ]

        // Single veto check
        for veto in ordered {
            var ctx = Self.validContext()
            makeFailing(veto)(&ctx)
            #expect(policy.evaluate(ctx) == .deny(veto))
        }

        // Precedence check: stack all vetoes from bottom up and verify highest priority wins
        var stacked = Self.validContext()
        for veto in ordered.reversed() {
            makeFailing(veto)(&stacked)
            #expect(policy.evaluate(stacked) == .deny(veto))
        }
    }

    @Test("T27 typing burst clears the candidate and a fresh dwell follows the quiet period")
    func t27TypingBurstClearsAndQuietThenDwell() {
        let config = Config() // typingLock=2.5, dwellCross=1.2
        let topo = Rig.dualExternal.topology
        var snap = WindowSnapshot(windows: Rig.dualExternal.windows, frontmostPID: 1001, frontmostBundleID: "com.mitchellh.ghostty", focusedWindowID: Rig.dualLeftTopID, takenAt: 0)
        var engine = FocusDecisionEngine(config: config)
        let targetPt = CGPoint(x: 4480, y: 720)

        var switchTimes: [TimeInterval] = []
        var nextKeyAt: TimeInterval = 0.15
        var lastKeyAt: TimeInterval?

        // 0..7.0s at 20 Hz; typing burst from 0.15s to 2.55s with 150ms gaps
        for i in 0..<141 {
            let t = Double(i) * 0.05
            if t + 1e-9 >= nextKeyAt && nextKeyAt <= 2.55 + 1e-9 {
                lastKeyAt = nextKeyAt
                nextKeyAt += 0.15
            }
            let elapsedSinceKey = lastKeyAt.map { max(0, t - $0) } ?? 1000
            let input = InputActivity(secondsSinceKeyboard: elapsedSinceKey)
            let out = engine.step(EngineInput(
                now: t,
                gaze: .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: t, usedHeadOnlyModel: false)),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: input,
                isPaused: false,
                isSessionActive: true
            ))
            if lastKeyAt != nil && elapsedSinceKey + 1e-9 < config.typingLockSeconds {
                #expect(out.candidateWindowID == nil)
                #expect(out.dwellProgress == 0)
            }
            if case .focus(let w) = out.action {
                switchTimes.append(t)
                engine.recordOutcome(.switched(.rungA), at: t)
                snap.focusedWindowID = w.windowID
            }
        }

        // Last key at 2.55 + 2.50 quiet = 5.05 + 1.20 fresh dwell = 6.25
        #expect(switchTimes.count == 1)
        #expect((switchTimes.first ?? 0) >= 6.25 - 1e-6)
    }

    @Test("T28 hard safety vetoes prevent switching")
    func t28HardSafetyVetoes() {
        let topo = Rig.dualExternal.topology
        let snap = WindowSnapshot(windows: Rig.dualExternal.windows, frontmostPID: 1001, frontmostBundleID: "com.mitchellh.ghostty", focusedWindowID: Rig.dualLeftTopID, takenAt: 0)
        let targetPt = CGPoint(x: 4480, y: 720)

        struct CaseSpec {
            let gaze: (Double) -> GazeObservation
            let faceCount: Int
            let input: InputActivity
            let paused: Bool
            let active: Bool
        }

        let cases: [CaseSpec] = [
            CaseSpec(gaze: { _ in .offScreen }, faceCount: 1, input: InputActivity(), paused: false, active: true),
            CaseSpec(gaze: { t in .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: t, usedHeadOnlyModel: false)) }, faceCount: 2, input: InputActivity(), paused: false, active: true),
            CaseSpec(gaze: { t in .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: t, usedHeadOnlyModel: false)) }, faceCount: 1, input: InputActivity(isSecureInputEnabled: true), paused: false, active: true),
            CaseSpec(gaze: { t in .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: t, usedHeadOnlyModel: false)) }, faceCount: 1, input: InputActivity(isPointerButtonDown: true), paused: false, active: true),
            CaseSpec(gaze: { t in .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: t, usedHeadOnlyModel: false)) }, faceCount: 1, input: InputActivity(), paused: false, active: false),
            CaseSpec(gaze: { t in .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: t, usedHeadOnlyModel: false)) }, faceCount: 1, input: InputActivity(), paused: true, active: true),
        ]

        for c in cases {
            var engine = FocusDecisionEngine(config: Config())
            for step in 0..<25 {
                let t = Double(step) * 0.05
                let out = engine.step(EngineInput(
                    now: t,
                    gaze: c.gaze(t),
                    faceCount: c.faceCount,
                    headPitch: 0,
                    pitchDownLimit: 0.4,
                    snapshot: snap,
                    topology: topo,
                    input: c.input,
                    isPaused: c.paused,
                    isSessionActive: c.active
                ))
                #expect(out.action == .none)
            }
        }
    }

    @Test("T39 pointer move and click clear candidate requiring fresh dwell")
    func t39PointerLocksClearCandidate() {
        let topo = Rig.dualExternal.topology
        let snap = WindowSnapshot(windows: Rig.dualExternal.windows, frontmostPID: 1001, frontmostBundleID: "com.mitchellh.ghostty", focusedWindowID: Rig.dualLeftTopID, takenAt: 0)
        let targetPt = CGPoint(x: 4480, y: 720)

        for inputDuringLock in [
            InputActivity(secondsSincePointerMove: 0.5),
            InputActivity(secondsSincePointerClick: 1.0),
        ] {
            var engine = FocusDecisionEngine(config: Config.v1Mechanics)
            // Accumulate partial dwell at t=0.0..0.2
            for t in [0.0, 0.1, 0.2] {
                _ = engine.step(EngineInput(now: t, gaze: .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: t, usedHeadOnlyModel: false)), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
            }
            // Pointer lock triggers -> clears candidate
            let locked = engine.step(EngineInput(now: 0.25, gaze: .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: 0.25, usedHeadOnlyModel: false)), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: inputDuringLock, isPaused: false, isSessionActive: true))
            #expect(locked.veto == .pointerActive)
            #expect(locked.candidateWindowID == nil)

            // Lock expires at t=1.0; must NOT commit at t=1.05 or t=1.20 (needs fresh 0.30s dwell)
            let at100 = engine.step(EngineInput(now: 1.00, gaze: .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: 1.00, usedHeadOnlyModel: false)), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
            #expect(at100.action == .none)
            let at120 = engine.step(EngineInput(now: 1.20, gaze: .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: 1.20, usedHeadOnlyModel: false)), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
            #expect(at120.action == .none)
            let at130 = engine.step(EngineInput(now: 1.30, gaze: .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: 1.30, usedHeadOnlyModel: false)), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
            #expect(at130.action == .focus(snap.window(id: Rig.dualRightRightID)!))
        }
    }

    @Test("T40 flagsChanged modifier counts as typing")
    func t40ModifierCountsAsTyping() {
        let policy = DefaultSafetyGuardPolicy()
        var ctx = Self.validContext(now: 10.0)
        // secondsSinceKeyboard represents min(keyDown, flagsChanged)
        ctx.input = InputActivity(secondsSinceKeyboard: 0.4)
        #expect(policy.evaluate(ctx) == .deny(.typing))
    }

    @Test("T41 looking down at keyboard vetoes while bottom terminal reachable")
    func t41LookDownGuardVsBottomTerminal() {
        let rig = Rig.deskThree
        let config = Config()
        var user = SyntheticUser(seed: 1)
        guard case .success(let profile) = user.calibrate(rig: rig, config: config, noise: false) else {
            Issue.record("Calibration failed")
            return
        }

        let snap = WindowSnapshot(
            windows: rig.windows,
            frontmostPID: 1001,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: Rig.deskMainLeftID,
            takenAt: 0
        )

        // Keyboard 150 mm below lowest panel (built-in bottom edge is around y = -445, so y = -600, z = 380)
        var kbPipe = FocusPipeline(config: config, profile: profile)
        let kbPoint = Vec3(x: 0, y: -600, z: 380)
        for i in 0..<30 {
            let t = Double(i) * 0.05
            let f = user.features(lookingAt: kbPoint, eyePositionMM: rig.eyePositionMM, timestamp: t, noise: false)
            let out = kbPipe.ingest(.features(f), env: PipelineEnvironment(snapshot: snap, topology: rig.topology, input: InputActivity(), isPaused: false, isSessionActive: true, now: t))
            #expect(out.action == .none)
            #expect(out.veto == .lookingDown || out.veto == .noGaze)
        }

        // Bottom-row terminal (deskBuiltinTermID) is still reachable
        var termPipe = FocusPipeline(config: config, profile: profile)
        let builtinTerm = snap.window(id: Rig.deskBuiltinTermID)!
        let builtinPt = CGPoint(x: builtinTerm.bounds.midX, y: builtinTerm.bounds.midY)
        var switched = false
        for i in 0..<30 {
            let t = Double(i) * 0.05
            let f = user.features(lookingAtGlobalPoint: builtinPt, rig: rig, timestamp: t, noise: false)
            let out = termPipe.ingest(.features(f), env: PipelineEnvironment(snapshot: snap, topology: rig.topology, input: InputActivity(), isPaused: false, isSessionActive: true, now: t))
            if case .focus(let w) = out.action, w.windowID == Rig.deskBuiltinTermID {
                switched = true
            }
        }
        #expect(switched)
    }

    @Test("T48 empty topology and uncalibrated topology vetoes")
    func t48EmptyAndUncalibratedTopologies() {
        let rig = Rig.dualExternal
        var user = SyntheticUser(seed: 1)
        guard case .success(let profile) = user.calibrate(rig: rig, noise: false) else {
            Issue.record("Calibration failed")
            return
        }
        let snap = WindowSnapshot(windows: rig.windows, frontmostPID: 1001, frontmostBundleID: "com.mitchellh.ghostty", focusedWindowID: Rig.dualLeftTopID, takenAt: 0)
        let sample = user.features(lookingAtUV: (0.5, 0.5), on: rig.displays[0], rig: rig, timestamp: 1.0, noise: false)

        // Empty topology -> no crash, zero switches, veto .noGaze
        var emptyPipe = FocusPipeline(config: Config(), profile: profile)
        let outEmpty = emptyPipe.ingest(.features(sample), env: PipelineEnvironment(snapshot: snap, topology: .empty, input: InputActivity(), isPaused: false, isSessionActive: true, now: 1.0))
        #expect(outEmpty.action == .none)
        #expect(outEmpty.veto == .noGaze)

        // Non-empty topology with no calibrated display -> veto .uncalibrated
        let unknownDisp = DisplayDescriptor(id: 99, uuid: "disp-unknown", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), physicalSizeMM: CGSize(width: 500, height: 300), isBuiltin: false, isMain: true)
        var uncalPipe = FocusPipeline(config: Config(), profile: profile)
        let outUncal = uncalPipe.ingest(.features(sample), env: PipelineEnvironment(snapshot: snap, topology: DisplayTopology(displays: [unknownDisp]), input: InputActivity(), isPaused: false, isSessionActive: true, now: 1.0))
        #expect(outUncal.action == .none)
        #expect(outUncal.veto == .uncalibrated)
    }

    @Test("T54 respectSecureInput false disables only secureInput veto")
    func t54RespectSecureInputOverride() {
        let policy = DefaultSafetyGuardPolicy()
        var ctx = Self.validContext(now: 10.0)
        ctx.config.respectSecureInput = false
        ctx.input.isSecureInputEnabled = true

        #expect(policy.evaluate(ctx) == .allow)

        // Other vetoes still fire normally
        ctx.input.secondsSinceKeyboard = 0.2
        #expect(policy.evaluate(ctx) == .deny(.typing))

        ctx.isPaused = true
        #expect(policy.evaluate(ctx) == .deny(.paused))
    }

    @Test("T59 SessionActivity truth table rejects lock sleep and missing dictionary")
    func t59SessionActivityTable() {
        #expect(SessionActivity.isActive(SessionSignals(
            dictionaryAvailable: true, onConsole: true, screenLocked: false, systemSleeping: false, displaysSleeping: false
        )) == true)
        #expect(SessionActivity.isActive(SessionSignals(
            dictionaryAvailable: true, onConsole: true, screenLocked: true, systemSleeping: false, displaysSleeping: false
        )) == false)
        // Simulated unlock notification where dictionary still reports screenLocked == true
        let spoofedUnlockSignals = SessionSignals(
            dictionaryAvailable: true, onConsole: true, screenLocked: true, systemSleeping: false, displaysSleeping: false
        )
        #expect(SessionActivity.isActive(spoofedUnlockSignals) == false)
        #expect(SessionActivity.isActive(SessionSignals(
            dictionaryAvailable: false, onConsole: true, screenLocked: false, systemSleeping: false, displaysSleeping: false
        )) == false)
        #expect(SessionActivity.isActive(SessionSignals(
            dictionaryAvailable: true, onConsole: false, screenLocked: false, systemSleeping: false, displaysSleeping: false
        )) == false)
        #expect(SessionActivity.isActive(SessionSignals(
            dictionaryAvailable: true, onConsole: true, screenLocked: false, systemSleeping: true, displaysSleeping: false
        )) == false)
        #expect(SessionActivity.isActive(SessionSignals(
            dictionaryAvailable: true, onConsole: true, screenLocked: false, systemSleeping: false, displaysSleeping: true
        )) == false)
    }

    @Test("T62 SecurityAgent window on another display vetoes switching even with respectSecureInput false")
    func t62SecurityPromptOnOtherDisplayVetoesEngine() {
        let policy = DefaultSafetyGuardPolicy()
        var ctx = Self.validContext()
        ctx.securityPromptVisible = true
        #expect(policy.evaluate(ctx) == .deny(.sourceNotAllowed))
        ctx.config.respectSecureInput = false
        #expect(policy.evaluate(ctx) == .deny(.sourceNotAllowed))

        let topo = Rig.dualExternal.topology
        let targetWin = Rig.dualExternal.windows.first { $0.windowID == Rig.dualRightRightID }!
        let targetPt = CGPoint(x: targetWin.bounds.midX, y: targetWin.bounds.midY)
        let promptWin = WindowDescriptor(
            windowID: 999,
            pid: 9999,
            bundleID: "com.apple.SecurityAgent",
            bounds: CGRect(x: 100, y: 100, width: 420, height: 220),
            zIndex: 0,
            layer: 8
        )
        let snapWithPrompt = WindowSnapshot(
            windows: [promptWin] + Rig.dualExternal.windows,
            frontmostPID: 1001,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: Rig.dualLeftTopID,
            takenAt: 0
        )

        for respectSecure in [true, false] {
            var cfg = Config.v1Mechanics
            cfg.respectSecureInput = respectSecure
            var engine = FocusDecisionEngine(config: cfg)
            var sawFocus = false
            for step in 0..<12 {
                let t = Double(step) * 0.05
                let out = engine.step(EngineInput(
                    now: t,
                    gaze: .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: t, usedHeadOnlyModel: false)),
                    faceCount: 1,
                    headPitch: 0,
                    pitchDownLimit: 0.4,
                    snapshot: snapWithPrompt,
                    topology: topo,
                    input: InputActivity(),
                    isPaused: false,
                    isSessionActive: true
                ))
                if case .focus = out.action {
                    sawFocus = true
                }
                #expect(out.veto == .sourceNotAllowed)
            }
            #expect(!sawFocus)
        }

        // Removing the prompt restores switching on the same gaze trajectory
        let snapClean = WindowSnapshot(
            windows: Rig.dualExternal.windows,
            frontmostPID: 1001,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: Rig.dualLeftTopID,
            takenAt: 0
        )
        var cleanEngine = FocusDecisionEngine(config: Config.v1Mechanics)
        var restoredSwitch = false
        for step in 0..<10 {
            let t = Double(step) * 0.05
            let out = cleanEngine.step(EngineInput(
                now: t,
                gaze: .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: t, usedHeadOnlyModel: false)),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snapClean,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            if case .focus(let w) = out.action, w.windowID == Rig.dualRightRightID {
                restoredSwitch = true
            }
        }
        #expect(restoredSwitch)
    }

    @Test("T63 hardBlocklist overrides requireAllowedSource false")
    func t63HardBlocklistOverridesRequireAllowedSourceFalse() {
        let policy = DefaultSafetyGuardPolicy()
        let requiredNewIDs = [
            "com.apple.LocalAuthentication.UIAgent",
            "com.apple.UserNotificationCenter",
            "com.apple.ScreenSharing",
            "com.apple.Settings",
        ]
        for id in requiredNewIDs {
            #expect(Config.hardBlocklist.contains(id))
        }

        for blocked in Config.hardBlocklist {
            var ctx = Self.validContext()
            ctx.config.requireAllowedSource = false
            ctx.frontmostBundleID = blocked
            #expect(policy.evaluate(ctx) == .deny(.sourceNotAllowed))
        }

        var unblocked = Self.validContext()
        unblocked.config.requireAllowedSource = false
        unblocked.frontmostBundleID = "com.example.CustomEditor"
        #expect(policy.evaluate(unblocked) == .allow)
    }

    @Test("T81 all five input classes clear candidates and enforce full quiet plus fresh dwell")
    func t81InputClassesQuietPeriods() {
        let config = Config()
        let topo = Rig.dualExternal.topology
        let snap = WindowSnapshot(
            windows: Rig.dualExternal.windows,
            frontmostPID: 1001,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: Rig.dualLeftTopID,
            takenAt: 0
        )
        let targetPt = CGPoint(x: 4480, y: 720)

        struct InputClassRow {
            let name: String
            let expectedVeto: SafetyVeto
            let quietSeconds: TimeInterval
            let makeInput: @Sendable (TimeInterval) -> InputActivity
        }

        let rows: [InputClassRow] = [
            InputClassRow(
                name: "keyboard",
                expectedVeto: .typing,
                quietSeconds: 2.5,
                makeInput: { t in
                    t < 0.25 ? InputActivity() : InputActivity(secondsSinceKeyboard: t - 0.25)
                }
            ),
            InputClassRow(
                name: "modifierHeld",
                expectedVeto: .typing,
                quietSeconds: 0.0,
                makeInput: { t in
                    if t < 0.25 { return InputActivity() }
                    if t < 1.00 - 1e-9 { return InputActivity(isModifierHeld: true) }
                    return InputActivity(isModifierHeld: false)
                }
            ),
            InputClassRow(
                name: "click",
                expectedVeto: .pointerActive,
                quietSeconds: 2.5,
                makeInput: { t in
                    t < 0.25 ? InputActivity() : InputActivity(secondsSincePointerClick: t - 0.25)
                }
            ),
            InputClassRow(
                name: "move",
                expectedVeto: .pointerActive,
                quietSeconds: 2.0,
                makeInput: { t in
                    t < 0.25 ? InputActivity() : InputActivity(secondsSincePointerMove: t - 0.25)
                }
            ),
            InputClassRow(
                name: "buttonHeld",
                expectedVeto: .pointerActive,
                quietSeconds: 0.0,
                makeInput: { t in
                    if t < 0.25 { return InputActivity() }
                    if t < 1.00 - 1e-9 { return InputActivity(isPointerButtonDown: true) }
                    return InputActivity(isPointerButtonDown: false)
                }
            ),
        ]

        for row in rows {
            var engine = FocusDecisionEngine(config: config)
            let lockReleaseAt: TimeInterval = (row.quietSeconds > 0) ? (0.25 + row.quietSeconds) : 1.00
            let expectedCommitAt = lockReleaseAt + config.dwellCrossDisplaySeconds
            var committedAt: TimeInterval?

            let maxStep = Int((expectedCommitAt / 0.05).rounded()) + 4
            for step in 0...maxStep {
                let t = Double(step) * 0.05
                let input = row.makeInput(t)
                let out = engine.step(EngineInput(
                    now: t,
                    gaze: .point(GazePoint(point: targetPt, displayUUID: "disp-right", confidence: 0.95, timestamp: t, usedHeadOnlyModel: false)),
                    faceCount: 1,
                    headPitch: 0,
                    pitchDownLimit: 0.4,
                    snapshot: snap,
                    topology: topo,
                    input: input,
                    isPaused: false,
                    isSessionActive: true
                ))
                if t >= 0.25 - 1e-9 && t < lockReleaseAt - 1e-6 {
                    #expect(out.veto == row.expectedVeto, "row=\(row.name) t=\(t)")
                    #expect(out.candidateWindowID == nil, "row=\(row.name) t=\(t)")
                    #expect(out.dwellProgress == 0, "row=\(row.name) t=\(t)")
                }
                if case .focus = out.action {
                    committedAt = t
                    break
                }
            }

            #expect(committedAt != nil, "row=\(row.name)")
            if let ct = committedAt {
                #expect(ct >= expectedCommitAt - 1e-6, "row=\(row.name)")
                #expect(abs(ct - expectedCommitAt) < 1e-6, "row=\(row.name)")
            }
        }
    }

    @Test("T85 password managers Spotlight occlusion and CoreAuthUI prompt alias")
    func t85PasswordManagersSpotlightAndCoreAuthUI() {
        let config = Config()
        let policy = DefaultSafetyGuardPolicy()

        // 1. 1Password window in front of Chrome gives .blocked, never Chrome
        let onePW = WindowDescriptor(
            windowID: 500,
            pid: 4001,
            bundleID: "com.1password.1password",
            bounds: CGRect(x: 100, y: 100, width: 600, height: 500),
            zIndex: 0,
            layer: 0
        )
        let chrome = WindowDescriptor(
            windowID: 501,
            pid: 3001,
            bundleID: "com.google.Chrome",
            bounds: CGRect(x: 50, y: 50, width: 1000, height: 800),
            zIndex: 1,
            layer: 0
        )
        let snap1PWOverChrome = WindowSnapshot(
            windows: [onePW, chrome],
            frontmostPID: 3001,
            frontmostBundleID: "com.google.Chrome",
            focusedWindowID: 501,
            takenAt: 0
        )
        #expect(WindowHitTester.hitTest(CGPoint(x: 300, y: 300), in: snap1PWOverChrome, config: config) == .blocked)

        // 2. Spotlight panel above layer 0 gives .blocked
        let spotlight = WindowDescriptor(
            windowID: 502,
            pid: 4002,
            bundleID: "com.apple.Spotlight",
            bounds: CGRect(x: 200, y: 150, width: 680, height: 420),
            zIndex: 0,
            layer: 8
        )
        let snapSpotlight = WindowSnapshot(
            windows: [spotlight, chrome],
            frontmostPID: 3001,
            frontmostBundleID: "com.google.Chrome",
            focusedWindowID: 501,
            takenAt: 0
        )
        #expect(WindowHitTester.hitTest(CGPoint(x: 400, y: 300), in: snapSpotlight, config: config) == .blocked)

        // 3. Password manager as frontmost app gives .sourceNotAllowed even with requireAllowedSource == false
        for frontID in ["com.1password.1password", "com.apple.Passwords", "com.apple.keychainaccess", "com.bitwarden.desktop"] {
            var ctx = Self.validContext()
            ctx.config.requireAllowedSource = false
            ctx.frontmostBundleID = frontID
            #expect(policy.evaluate(ctx) == .deny(.sourceNotAllowed))
        }

        // 4. Password manager window on another display does NOT raise global security prompt veto (AW8)
        let chromeRight = WindowDescriptor(
            windowID: 503,
            pid: 3001,
            bundleID: "com.google.Chrome",
            bounds: CGRect(x: 2600, y: 40, width: 1200, height: 1000),
            zIndex: 2,
            layer: 0
        )
        let snap1PWOtherDisplay = WindowSnapshot(
            windows: [onePW, chromeRight],
            frontmostPID: 1001,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: nil,
            takenAt: 0
        )
        #expect(WindowHitTester.securityPromptVisible(in: snap1PWOtherDisplay) == false)

        // 5. CoreAuthUI process name resolves to LocalAuthentication.UIAgent and classifies as .securityPrompt (RC3)
        let canonical = WindowClassifier.canonicalBundleID(bundleID: nil, ownerName: "CoreAuthUI")
        #expect(canonical == "com.apple.LocalAuthentication.UIAgent")
        let role = WindowClassifier.classify(
            layer: 8,
            alpha: 1.0,
            pid: 5000,
            ownPID: 999,
            bundleID: canonical,
            bounds: CGRect(x: 300, y: 200, width: 420, height: 220),
            displayBounds: [CGRect(x: 0, y: 0, width: 1496, height: 967)]
        )
        #expect(role == .securityPrompt)
    }
}
