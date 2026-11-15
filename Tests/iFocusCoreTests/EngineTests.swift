import CoreGraphics
import Foundation
import Testing
@testable import iFocusCore

@Suite("Engine")
struct EngineTests {
    private static func makePoint(
        _ p: CGPoint,
        displayUUID: String,
        at t: TimeInterval,
        confidence: Double = 0.95
    ) -> GazeObservation {
        .point(GazePoint(
            point: p,
            displayUUID: displayUUID,
            confidence: confidence,
            timestamp: t,
            usedHeadOnlyModel: false
        ))
    }

    private static func dualSnapshot(focusedID: UInt32 = Rig.dualLeftTopID, at t: TimeInterval = 0) -> WindowSnapshot {
        WindowSnapshot(
            windows: Rig.dualExternal.windows,
            frontmostPID: 1001,
            frontmostBundleID: "com.mitchellh.ghostty",
            focusedWindowID: focusedID,
            takenAt: t
        )
    }

    @Test("T19 dwell thresholds cross vs same display")
    func t19DwellThresholds() {
        let config = Config.v1Mechanics // cross=0.30, same=0.45
        let topo = Rig.dualExternal.topology
        let snap = Self.dualSnapshot()

        // Cross-display target: dualRightRightID at (4480, 720)
        var crossEngine = FocusDecisionEngine(config: config)
        let crossPt = CGPoint(x: 4480, y: 720)
        for step in 0..<6 {
            let t = Double(step) * 0.05 // 0.00 ... 0.25 (dwell minus one frame)
            let out = crossEngine.step(EngineInput(
                now: t,
                gaze: Self.makePoint(crossPt, displayUUID: "disp-right", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            #expect(out.action == .none)
        }
        let crossCommit = crossEngine.step(EngineInput(
            now: 0.30,
            gaze: Self.makePoint(crossPt, displayUUID: "disp-right", at: 0.30),
            faceCount: 1,
            headPitch: 0,
            pitchDownLimit: 0.4,
            snapshot: snap,
            topology: topo,
            input: InputActivity(),
            isPaused: false,
            isSessionActive: true
        ))
        #expect(crossCommit.action == .focus(snap.window(id: Rig.dualRightRightID)!))

        // Same-display target: dualLeftBottomID at (640, 1080)
        var sameEngine = FocusDecisionEngine(config: config)
        let samePt = CGPoint(x: 640, y: 1080)
        for step in 0..<9 {
            let t = Double(step) * 0.05 // 0.00 ... 0.40 (dwell minus one frame)
            let out = sameEngine.step(EngineInput(
                now: t,
                gaze: Self.makePoint(samePt, displayUUID: "disp-left", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            #expect(out.action == .none)
        }
        let sameCommit = sameEngine.step(EngineInput(
            now: 0.45,
            gaze: Self.makePoint(samePt, displayUUID: "disp-left", at: 0.45),
            faceCount: 1,
            headPitch: 0,
            pitchDownLimit: 0.4,
            snapshot: snap,
            topology: topo,
            input: InputActivity(),
            isPaused: false,
            isSessionActive: true
        ))
        #expect(sameCommit.action == .focus(snap.window(id: Rig.dualLeftBottomID)!))
    }

    @Test("T20 border jitter produces zero switches")
    func t20BorderJitterZeroSwitches() {
        let config = Config() // stickyMargin = 48
        let topo = Rig.dualExternal.topology
        let leftWin = WindowDescriptor(windowID: 1, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: 0, y: 0, width: 1280, height: 1440), zIndex: 0)
        let rightWin = WindowDescriptor(windowID: 2, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: 1280, y: 0, width: 1280, height: 1440), zIndex: 1)
        let snap = WindowSnapshot(windows: [leftWin, rightWin], frontmostPID: 1001, frontmostBundleID: "com.mitchellh.ghostty", focusedWindowID: 1, takenAt: 0)

        var engine = FocusDecisionEngine(config: config)
        var rng = SeededRNG(seed: 99)
        for step in 0..<200 { // 10 s at 20 Hz
            let t = Double(step) * 0.05
            let jitter = CGFloat((rng.nextDouble() * 2.0 - 1.0) * 30.0) // +/- 30 pt around x=1280
            let pt = CGPoint(x: 1280 + jitter, y: 720)
            let out = engine.step(EngineInput(
                now: t,
                gaze: Self.makePoint(pt, displayUUID: "disp-left", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            #expect(out.action == .none)
        }
    }

    @Test("T21 brief 100ms glance produces zero switches")
    func t21BriefGlanceZeroSwitches() {
        let topo = Rig.dualExternal.topology
        let snap = Self.dualSnapshot()
        var engine = FocusDecisionEngine(config: Config())

        for i in 0..<40 {
            let t = Double(i) * 0.05
            let lookingAtRight = (t >= 0.50 && t <= 0.60) // 100 ms glance
            let pt = lookingAtRight ? CGPoint(x: 4480, y: 720) : CGPoint(x: 640, y: 360)
            let uuid = lookingAtRight ? "disp-right" : "disp-left"
            let out = engine.step(EngineInput(
                now: t,
                gaze: Self.makePoint(pt, displayUUID: uuid, at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            #expect(out.action == .none)
        }
    }

    @Test("T22 candidate survives 100ms dropout and clears at 200ms")
    func t22DropoutSurvivalAndClear() {
        let topo = Rig.dualExternal.topology
        let snap = Self.dualSnapshot()
        let pt = CGPoint(x: 4480, y: 720)

        // 100 ms dropout (<= 0.12 s): candidate survives
        var eng1 = FocusDecisionEngine(config: Config.v1Mechanics)
        for t in [0.0, 0.05, 0.10] {
            _ = eng1.step(EngineInput(now: t, gaze: Self.makePoint(pt, displayUUID: "disp-right", at: t), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        }
        let drop100 = eng1.step(EngineInput(now: 0.20, gaze: .noFace, faceCount: 0, headPitch: nil, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        #expect(drop100.candidateWindowID == Rig.dualRightRightID)
        let resume = eng1.step(EngineInput(now: 0.30, gaze: Self.makePoint(pt, displayUUID: "disp-right", at: 0.30), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        #expect(resume.action == .focus(snap.window(id: Rig.dualRightRightID)!))

        // 200 ms dropout (> 0.12 s): candidate cleared
        var eng2 = FocusDecisionEngine(config: Config.v1Mechanics)
        for t in [0.0, 0.05, 0.10] {
            _ = eng2.step(EngineInput(now: t, gaze: Self.makePoint(pt, displayUUID: "disp-right", at: t), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        }
        let drop200 = eng2.step(EngineInput(now: 0.30, gaze: .noFace, faceCount: 0, headPitch: nil, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        #expect(drop200.candidateWindowID == nil)
    }

    @Test("T23 switch cooldown and failed switch backoff interaction")
    func t23CooldownAndFailureRecordOutcome() {
        var config = Config()
        config.switchCooldownSeconds = 0.60
        config.failureBackoffSeconds = 2.0
        var engine = FocusDecisionEngine(config: config)
        let topo = Rig.dualExternal.topology
        let snap = Self.dualSnapshot()
        let targetPt = CGPoint(x: 4480, y: 720)

        engine.recordOutcome(.switched(.rungA), at: 1.0)
        #expect(engine.lastSwitchAt == 1.0)
        let duringCooldown = engine.step(EngineInput(
            now: 1.3,
            gaze: Self.makePoint(targetPt, displayUUID: "disp-right", at: 1.3),
            faceCount: 1,
            headPitch: 0,
            pitchDownLimit: 0.4,
            snapshot: snap,
            topology: topo,
            input: InputActivity(),
            isPaused: false,
            isSessionActive: true
        ))
        #expect(duringCooldown.veto == .cooldown)
        #expect(duringCooldown.action == .none)

        // Failure does not move lastSwitchAt
        engine.recordOutcome(.failed(.unverified), at: 2.0)
        #expect(engine.lastSwitchAt == 1.0)
        #expect(engine.lastFailureAt == 2.0)
        #expect(engine.failureCount == 1)
    }

    @Test("T24 manual focus change adopted and clears pending")
    func t24ManualFocusAdoption() {
        let topo = Rig.dualExternal.topology
        let snap1 = Self.dualSnapshot(focusedID: Rig.dualLeftTopID)
        var engine = FocusDecisionEngine(config: Config())
        let pt = CGPoint(x: 4480, y: 720)

        // Start dwelling on dualRightRightID
        let out1 = engine.step(EngineInput(now: 0.0, gaze: Self.makePoint(pt, displayUUID: "disp-right", at: 0.0), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap1, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        #expect(out1.candidateWindowID == Rig.dualRightRightID)

        // User manually focuses dualRightRightID (e.g. via Cmd-Tab / click)
        let snap2 = Self.dualSnapshot(focusedID: Rig.dualRightRightID, at: 0.1)
        let out2 = engine.step(EngineInput(now: 0.1, gaze: Self.makePoint(pt, displayUUID: "disp-right", at: 0.1), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap2, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        #expect(out2.candidateWindowID == nil)
        #expect(out2.action == .none)
    }

    @Test("T25 displayFallback off vs on MRU selection")
    func t25DisplayFallbackOffVsOn() {
        let topo = Rig.dualExternal.topology
        let leftWin = WindowDescriptor(windowID: 1, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: 20, y: 20, width: 600, height: 600), zIndex: 0)
        let rightWin = WindowDescriptor(windowID: 2, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: 2600, y: 20, width: 600, height: 600), zIndex: 1)
        let snapRightFocused = WindowSnapshot(windows: [rightWin, leftWin], frontmostPID: 1001, frontmostBundleID: "com.mitchellh.ghostty", focusedWindowID: 2, takenAt: 0)
        let snapLeftFocused = WindowSnapshot(windows: [leftWin, rightWin], frontmostPID: 1001, frontmostBundleID: "com.mitchellh.ghostty", focusedWindowID: 1, takenAt: 1)
        // Gaze at empty desktop area on right monitor (4500, 1200) well outside rightWin and > 80 pt snap radius
        let emptyRightPt = CGPoint(x: 4500, y: 1200)

        // Default displayFallback = false -> nothing
        var offEngine = FocusDecisionEngine(config: Config.v1Mechanics)
        _ = offEngine.step(EngineInput(now: 0.0, gaze: Self.makePoint(CGPoint(x: 2800, y: 300), displayUUID: "disp-right", at: 0.0), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snapRightFocused, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        for t in [1.0, 1.2, 1.4] {
            let out = offEngine.step(EngineInput(now: t, gaze: Self.makePoint(emptyRightPt, displayUUID: "disp-right", at: t), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snapLeftFocused, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
            #expect(out.action == .none)
        }

        // displayFallback = true -> selects right display's MRU eligible window (rightWin)
        var onConfig = Config.v1Mechanics
        onConfig.displayFallback = true
        var onEngine = FocusDecisionEngine(config: onConfig)
        _ = onEngine.step(EngineInput(now: 0.0, gaze: Self.makePoint(CGPoint(x: 2800, y: 300), displayUUID: "disp-right", at: 0.0), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snapRightFocused, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        _ = onEngine.step(EngineInput(now: 1.0, gaze: Self.makePoint(emptyRightPt, displayUUID: "disp-right", at: 1.0), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snapLeftFocused, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        let outCommit = onEngine.step(EngineInput(now: 1.35, gaze: Self.makePoint(emptyRightPt, displayUUID: "disp-right", at: 1.35), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snapLeftFocused, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        #expect(outCommit.action == .focus(rightWin))
    }

    @Test("T42 dwell completed during cooldown commits immediately after")
    func t42CooldownDeferredCommit() {
        var config = Config()
        config.dwellCrossDisplaySeconds = 0.30
        config.switchCooldownSeconds = 0.60
        var engine = FocusDecisionEngine(config: config)
        let topo = Rig.dualExternal.topology
        let snap = Self.dualSnapshot()
        let pt = CGPoint(x: 4480, y: 720)

        engine.recordOutcome(.switched(.rungA), at: 1.00)

        // Gaze enters target at 1.10; dwell finishes at 1.40 while cooldown lasts until 1.60
        for t in [1.10, 1.25, 1.40, 1.55] {
            let out = engine.step(EngineInput(now: t, gaze: Self.makePoint(pt, displayUUID: "disp-right", at: t), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
            #expect(out.action == .none)
            #expect(out.veto == .cooldown)
        }

        // First step after cooldown expires (1.60) commits immediately without a second dwell!
        let commit = engine.step(EngineInput(now: 1.60, gaze: Self.makePoint(pt, displayUUID: "disp-right", at: 1.60), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        #expect(commit.action == .focus(snap.window(id: Rig.dualRightRightID)!))
    }

    @Test("T43 failed switch backoff suppresses retries until expired")
    func t43FailureBackoff() {
        var config = Config.v1Mechanics
        config.failureBackoffSeconds = 2.0
        var engine = FocusDecisionEngine(config: config)
        let topo = Rig.dualExternal.topology
        let snap = Self.dualSnapshot()
        let pt = CGPoint(x: 4480, y: 720)

        engine.recordOutcome(.failed(.unverified), at: 1.0)

        let blocked = engine.step(EngineInput(now: 2.5, gaze: Self.makePoint(pt, displayUUID: "disp-right", at: 2.5), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        #expect(blocked.veto == .failureBackoff)
        #expect(blocked.action == .none)

        // After 3.0s backoff expires -> fresh dwell succeeds
        let start = engine.step(EngineInput(now: 3.1, gaze: Self.makePoint(pt, displayUUID: "disp-right", at: 3.1), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        #expect(start.veto == nil)
        let commit = engine.step(EngineInput(now: 3.45, gaze: Self.makePoint(pt, displayUUID: "disp-right", at: 3.45), faceCount: 1, headPitch: 0, pitchDownLimit: 0.4, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        #expect(commit.action == .focus(snap.window(id: Rig.dualRightRightID)!))
    }

    @Test("T51 pre-commit confirm rejects stale key press or disappeared target")
    func t51ConfirmRejectsTypingOrDisappearedTarget() async {
        let rig = Rig.dualExternal
        var user = SyntheticUser(seed: 1)
        guard case .success(let profile) = user.calibrate(rig: rig, noise: false) else {
            Issue.record("Calibration failed")
            return
        }

        let targetWin = rig.windows.first { $0.windowID == Rig.dualRightRightID }!
        let targetPt = CGPoint(x: targetWin.bounds.midX, y: targetWin.bounds.midY)
        let snap = Self.dualSnapshot()

        // 1. Direct pipeline confirm rejects fresh key press and disappeared target
        var pipe = FocusPipeline(config: Config.v1Mechanics, profile: profile)
        let f1 = user.features(lookingAtGlobalPoint: targetPt, rig: rig, timestamp: 0.0, noise: false)
        let f2 = user.features(lookingAtGlobalPoint: targetPt, rig: rig, timestamp: 0.35, noise: false)
        _ = pipe.ingest(.features(f1), env: PipelineEnvironment(snapshot: snap, topology: rig.topology, input: InputActivity(), isPaused: false, isSessionActive: true, now: 0.0))
        let out = pipe.ingest(.features(f2), env: PipelineEnvironment(snapshot: snap, topology: rig.topology, input: InputActivity(), isPaused: false, isSessionActive: true, now: 0.35))
        #expect(out.action == .focus(targetWin))

        let typingInput = InputActivity(secondsSinceKeyboard: 0.02)
        #expect(pipe.confirm(targetWin, env: PipelineEnvironment(snapshot: snap, topology: rig.topology, input: typingInput, isPaused: false, isSessionActive: true, now: 0.36)) == false)

        let missingSnap = WindowSnapshot(windows: snap.windows.filter { $0.windowID != targetWin.windowID }, frontmostPID: snap.frontmostPID, frontmostBundleID: snap.frontmostBundleID, focusedWindowID: snap.focusedWindowID, takenAt: 0.36)
        #expect(pipe.confirm(targetWin, env: PipelineEnvironment(snapshot: missingSnap, topology: rig.topology, input: InputActivity(), isPaused: false, isSessionActive: true, now: 0.36)) == false)

        // 2. Coordinator takes fresh snapshot/input for confirm and never calls switcher when rejected
        actor ConfirmInterceptCatalog: WindowCatalogService {
            var calls = 0
            let base: WindowSnapshot
            let onConfirmRefresh: @Sendable () -> WindowSnapshot
            init(base: WindowSnapshot, onConfirmRefresh: @escaping @Sendable () -> WindowSnapshot) {
                self.base = base
                self.onConfirmRefresh = onConfirmRefresh
            }
            func snapshot() async -> WindowSnapshot {
                calls += 1
                if calls <= 2 {
                    return base
                }
                return onConfirmRefresh()
            }
        }

        let preGeneratedEvents: [GazeEvent] = [
            .features(user.features(lookingAtGlobalPoint: targetPt, rig: rig, timestamp: 0.0, noise: false)),
            .features(user.features(lookingAtGlobalPoint: targetPt, rig: rig, timestamp: 0.35, noise: false)),
        ]

        // Clean deterministic clock-stepping feed via PreparedScenario for A (typing), B (window vanished), and unperturbed control
        enum ConfirmAbortMode {
            case none
            case typingOnConfirm
            case dropWindowOnConfirm
        }

        func runConfirmAbortTest(mode: ConfirmAbortMode) async -> [WindowDescriptor] {
            let clock = VirtualClock(startAt: 0)
            let inputProvider = ManualInputActivityProvider()
            let switcher = SimFocusSwitcher()
            let catalog = ConfirmInterceptCatalog(base: snap) {
                switch mode {
                case .none:
                    return snap
                case .typingOnConfirm:
                    inputProvider.update(InputActivity(secondsSinceKeyboard: 0.01))
                    return snap
                case .dropWindowOnConfirm:
                    return missingSnap
                }
            }
            let prepared = PreparedScenario(
                scenario: Scenario(
                    name: "confirm-abort",
                    rig: rig,
                    initialFocusedWindowID: Rig.dualLeftTopID,
                    duration: 0.4,
                    segments: [],
                    expectedSwitches: []
                ),
                profile: profile,
                steps: [
                    (0.0, preGeneratedEvents[0], InputActivity(), false, true),
                    (0.35, preGeneratedEvents[1], InputActivity(), false, true),
                ]
            )
            let gaze = SimGazeEstimator(
                prepared: prepared,
                clock: clock,
                inputProvider: inputProvider,
                sessionProvider: ManualSessionStateProvider(active: true)
            )
            let coordinator = FocusCoordinator(
                config: Config.v1Mechanics,
                profile: profile,
                gazeEstimator: gaze,
                topologyService: SimDisplayTopologyService(topology: rig.topology),
                windowCatalog: catalog,
                inputProvider: inputProvider,
                sessionProvider: ManualSessionStateProvider(active: true),
                focusSwitcher: switcher,
                clock: clock
            )
            await coordinator.runUntilStreamFinishes()
            return switcher.recordedTargets()
        }

        let switchedUnperturbed = await runConfirmAbortTest(mode: .none)
        let switchedOnKey = await runConfirmAbortTest(mode: .typingOnConfirm)
        let switchedOnDisappear = await runConfirmAbortTest(mode: .dropWindowOnConfirm)
        #expect(switchedUnperturbed.count == 1)
        #expect(switchedOnKey.isEmpty)
        #expect(switchedOnDisappear.isEmpty)
    }

    @Test("T67 challenger candidate tolerates outlier prevents early switch and blocks alternation")
    func t67ChallengerCandidateOutlierAndAlternation() {
        let config = Config.v1Mechanics
        let topo = Rig.dualExternal.topology
        let snap = Self.dualSnapshot(focusedID: Rig.dualLeftTopID)
        let ptB = CGPoint(x: 640, y: 1080)  // dualLeftBottomID
        let ptC = CGPoint(x: 1920, y: 720)  // dualLeftRightApp2ID

        // 1. One-in-six outlier on C while dwelling on B: commits B <= 0.45 + dropout + 1 frame.
        var engineOutlier = FocusDecisionEngine(config: config)
        var outlierCommitTime: TimeInterval?
        var outlierTarget: UInt32?
        for step in 0...60 {
            let t = Double(step) * 0.05
            let pt = (step % 6 == 3) ? ptC : ptB
            let out = engineOutlier.step(EngineInput(
                now: t,
                gaze: Self.makePoint(pt, displayUUID: "disp-left", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            if case .focus(let w) = out.action {
                outlierCommitTime = t
                outlierTarget = w.windowID
                break
            }
        }
        #expect(outlierTarget == Rig.dualLeftBottomID)
        if let commitTime = outlierCommitTime {
            #expect(commitTime <= config.dwellSameDisplaySeconds + config.candidateDropoutSeconds + 0.05 + 1e-9)
        } else {
            Issue.record("Expected B to commit despite 1-in-6 outlier")
        }

        // 2. Control 1: 0.2 s on B (0.00..0.15) then steady on C (entry 0.20) commits C at entry + dwell, never B.
        var engineSwitch = FocusDecisionEngine(config: config)
        var switchCommits: [(time: TimeInterval, id: UInt32)] = []
        for step in 0...30 {
            let t = Double(step) * 0.05
            let pt = (t < 0.20 - 1e-9) ? ptB : ptC
            let out = engineSwitch.step(EngineInput(
                now: t,
                gaze: Self.makePoint(pt, displayUUID: "disp-left", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            if case .focus(let w) = out.action {
                switchCommits.append((t, w.windowID))
            }
        }
        #expect(switchCommits.count >= 1)
        #expect(switchCommits.allSatisfy { $0.id == Rig.dualLeftRightApp2ID })
        if let firstCommit = switchCommits.first {
            #expect(abs(firstCommit.time - (0.20 + config.dwellSameDisplaySeconds)) < 1e-6)
        }

        // 3. Control 2: strict B, C alternation for 3 s commits neither.
        var engineAlt = FocusDecisionEngine(config: config)
        var altCommits: [UInt32] = []
        for step in 0...60 {
            let t = Double(step) * 0.05
            let pt = (step % 2 == 0) ? ptB : ptC
            let out = engineAlt.step(EngineInput(
                now: t,
                gaze: Self.makePoint(pt, displayUUID: "disp-left", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            if case .focus(let w) = out.action {
                altCommits.append(w.windowID)
            }
        }
        #expect(altCommits.isEmpty)
    }

    @Test("T80 quiet period clears candidate and requires full 2.5s quiet plus 1.2s fresh dwell")
    func t80QuietPeriodAndFreshDwellReset() {
        let config = Config()
        let topo = Rig.dualExternal.topology
        let snap = Self.dualSnapshot(focusedID: Rig.dualLeftTopID)
        let targetPt = CGPoint(x: 4480, y: 720) // cross-display dualRightRightID

        // 1. Key burst every 150 ms up to 1.50 s -> 0 candidate & 0 progress throughout quiet window, commit at +3.7 s (5.20 s).
        var engine1 = FocusDecisionEngine(config: config)
        var lastKeyAt: TimeInterval?
        var nextKeyAt: TimeInterval = 0.0
        var commitTime: TimeInterval?

        for step in 0...120 {
            let t = Double(step) * 0.05
            if t + 1e-9 >= nextKeyAt && nextKeyAt <= 1.50 + 1e-9 {
                lastKeyAt = nextKeyAt
                nextKeyAt += 0.15
            }
            let elapsed = lastKeyAt.map { max(0, t - $0) } ?? 1000
            let out = engine1.step(EngineInput(
                now: t,
                gaze: Self.makePoint(targetPt, displayUUID: "disp-right", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(secondsSinceKeyboard: elapsed),
                isPaused: false,
                isSessionActive: true
            ))
            if elapsed + 1e-9 < config.typingLockSeconds {
                #expect(out.candidateWindowID == nil)
                #expect(out.dwellProgress == 0)
                #expect(out.action == .none)
            }
            if case .focus = out.action {
                commitTime = t
                break
            }
        }
        #expect(commitTime != nil)
        if let ct = commitTime {
            #expect(ct >= 1.50 + 3.70 - 1e-6)
            #expect(abs(ct - 5.20) < 1e-6)
        }

        // 2. One key 0.8 s into dwell (key at 0.0 -> quiet ends 2.50 -> dwell to 3.25 -> key at 3.30) restarts full 2.5 + 1.2 -> commit at 7.00.
        var engine2 = FocusDecisionEngine(config: config)
        var lastKey2: TimeInterval = 0.0
        var commit2: TimeInterval?
        for step in 0...160 {
            let t = Double(step) * 0.05
            if abs(t - 3.30) < 1e-6 {
                lastKey2 = 3.30
            }
            let elapsed = max(0, t - lastKey2)
            let out = engine2.step(EngineInput(
                now: t,
                gaze: Self.makePoint(targetPt, displayUUID: "disp-right", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(secondsSinceKeyboard: elapsed),
                isPaused: false,
                isSessionActive: true
            ))
            if abs(t - 3.30) < 1e-6 {
                #expect(out.veto == .typing)
                #expect(out.candidateWindowID == nil)
                #expect(out.dwellProgress == 0)
            }
            if case .focus = out.action {
                commit2 = t
                break
            }
        }
        #expect(commit2 != nil)
        if let ct2 = commit2 {
            #expect(ct2 >= 3.30 + 3.70 - 1e-6)
            #expect(abs(ct2 - 7.00) < 1e-6)
        }
    }

    @Test("T82 dropout veto interleaved with typing cannot preserve candidate across lock")
    func t82DropoutInterleavedWithTypingClearsCandidate() {
        let config = Config()
        let topo = Rig.dualExternal.topology
        let snap = Self.dualSnapshot(focusedID: Rig.dualLeftTopID)
        let targetPt = CGPoint(x: 4480, y: 720)

        var engine = FocusDecisionEngine(config: config)
        // Build partial dwell 0.0..0.50
        for step in 0...10 {
            let t = Double(step) * 0.05
            let out = engine.step(EngineInput(
                now: t,
                gaze: Self.makePoint(targetPt, displayUUID: "disp-right", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            #expect(out.candidateWindowID == Rig.dualRightRightID)
        }

        // At 0.55..0.80: key typed at 0.55 AND user glances down (lookingDown precedes typing in policy).
        for step in 11...16 {
            let t = Double(step) * 0.05
            let out = engine.step(EngineInput(
                now: t,
                gaze: Self.makePoint(targetPt, displayUUID: "disp-right", at: t),
                faceCount: 1,
                headPitch: 0.60,
                pitchDownLimit: 0.30,
                snapshot: snap,
                topology: topo,
                input: InputActivity(secondsSinceKeyboard: t - 0.55),
                isPaused: false,
                isSessionActive: true
            ))
            #expect(out.veto == .lookingDown)
            #expect(out.action == .none)
        }

        // Look back up while typing lock (2.5s) is still active at t = 0.85 -> typing (.clear) wipes candidate
        let backUp = engine.step(EngineInput(
            now: 0.85,
            gaze: Self.makePoint(targetPt, displayUUID: "disp-right", at: 0.85),
            faceCount: 1,
            headPitch: 0,
            pitchDownLimit: 0.30,
            snapshot: snap,
            topology: topo,
            input: InputActivity(secondsSinceKeyboard: 0.85 - 0.55),
            isPaused: false,
            isSessionActive: true
        ))
        #expect(backUp.veto == .typing)
        #expect(backUp.candidateWindowID == nil)
        #expect(backUp.dwellProgress == 0)

        // Looking down throughout the entire quiet window (with 20 Hz .lookingDown samples) and returning expires candidate (progress 0).
        var engineLongDown = FocusDecisionEngine(config: config)
        _ = engineLongDown.step(EngineInput(now: 0.0, gaze: Self.makePoint(targetPt, displayUUID: "disp-right", at: 0.0), faceCount: 1, headPitch: 0, pitchDownLimit: 0.30, snapshot: snap, topology: topo, input: InputActivity(), isPaused: false, isSessionActive: true))
        for step in 1...61 {
            let t = Double(step) * 0.05
            _ = engineLongDown.step(EngineInput(now: t, gaze: Self.makePoint(targetPt, displayUUID: "disp-right", at: t), faceCount: 1, headPitch: 0.60, pitchDownLimit: 0.30, snapshot: snap, topology: topo, input: InputActivity(secondsSinceKeyboard: t), isPaused: false, isSessionActive: true))
        }
        let afterLongDown = engineLongDown.step(EngineInput(now: 3.10, gaze: Self.makePoint(targetPt, displayUUID: "disp-right", at: 3.10), faceCount: 1, headPitch: 0, pitchDownLimit: 0.30, snapshot: snap, topology: topo, input: InputActivity(secondsSinceKeyboard: 3.0), isPaused: false, isSessionActive: true))
        #expect(afterLongDown.action == .none)
        #expect(afterLongDown.dwellProgress == 0)
    }

    @Test("T83 idle hands default dwell thresholds 1.2s cross-display and 1.5s same-display")
    func t83DefaultDwellWithIdleHands() {
        let config = Config()
        let topo = Rig.dualExternal.topology
        let snap = Self.dualSnapshot(focusedID: Rig.dualLeftTopID)

        // Cross-display: dualRightRightID commits at 1.20 s, not 1.15 s
        var crossEngine = FocusDecisionEngine(config: config)
        let crossPt = CGPoint(x: 4480, y: 720)
        for step in 0..<24 {
            let t = Double(step) * 0.05 // 0.00 .. 1.15
            let out = crossEngine.step(EngineInput(
                now: t,
                gaze: Self.makePoint(crossPt, displayUUID: "disp-right", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            #expect(out.action == .none)
        }
        let crossCommit = crossEngine.step(EngineInput(
            now: 1.20,
            gaze: Self.makePoint(crossPt, displayUUID: "disp-right", at: 1.20),
            faceCount: 1,
            headPitch: 0,
            pitchDownLimit: 0.4,
            snapshot: snap,
            topology: topo,
            input: InputActivity(),
            isPaused: false,
            isSessionActive: true
        ))
        #expect(crossCommit.action == .focus(snap.window(id: Rig.dualRightRightID)!))

        // Same-display: dualLeftBottomID commits at 1.50 s, not 1.45 s
        var sameEngine = FocusDecisionEngine(config: config)
        let samePt = CGPoint(x: 640, y: 1080)
        for step in 0..<30 {
            let t = Double(step) * 0.05 // 0.00 .. 1.45
            let out = sameEngine.step(EngineInput(
                now: t,
                gaze: Self.makePoint(samePt, displayUUID: "disp-left", at: t),
                faceCount: 1,
                headPitch: 0,
                pitchDownLimit: 0.4,
                snapshot: snap,
                topology: topo,
                input: InputActivity(),
                isPaused: false,
                isSessionActive: true
            ))
            #expect(out.action == .none)
        }
        let sameCommit = sameEngine.step(EngineInput(
            now: 1.50,
            gaze: Self.makePoint(samePt, displayUUID: "disp-left", at: 1.50),
            faceCount: 1,
            headPitch: 0,
            pitchDownLimit: 0.4,
            snapshot: snap,
            topology: topo,
            input: InputActivity(),
            isPaused: false,
            isSessionActive: true
        ))
        #expect(sameCommit.action == .focus(snap.window(id: Rig.dualLeftBottomID)!))
    }
}
