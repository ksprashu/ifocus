import CoreGraphics
import Foundation

public struct ScenarioResult: Sendable, Equatable {
    public var scenarioName: String
    public var seed: UInt64
    public var profile: CalibrationProfile
    public var decisionLog: [DecisionLogEntry]
    public var actualSwitches: [UInt32]
    public var expectedSwitches: [UInt32]
    public var switchTimestamps: [(windowID: UInt32, timestamp: TimeInterval)]

    public var passed: Bool {
        actualSwitches == expectedSwitches
    }

    public static func == (lhs: ScenarioResult, rhs: ScenarioResult) -> Bool {
        lhs.scenarioName == rhs.scenarioName
            && lhs.seed == rhs.seed
            && lhs.profile == rhs.profile
            && lhs.decisionLog == rhs.decisionLog
            && lhs.actualSwitches == rhs.actualSwitches
            && lhs.expectedSwitches == rhs.expectedSwitches
    }
}

public struct PreparedScenario: Sendable {
    public var scenario: Scenario
    public var profile: CalibrationProfile
    public var seed: UInt64
    public var steps: [(timestamp: TimeInterval, event: GazeEvent, input: InputActivity, isPaused: Bool, isSessionActive: Bool)]

    public init(
        scenario: Scenario,
        profile: CalibrationProfile,
        seed: UInt64 = 0,
        steps: [(timestamp: TimeInterval, event: GazeEvent, input: InputActivity, isPaused: Bool, isSessionActive: Bool)]
    ) {
        self.scenario = scenario
        self.profile = profile
        self.seed = seed
        self.steps = steps
    }
}

public enum ScenarioRunner {
    public static func prepare(
        _ scenario: Scenario,
        seed: UInt64 = 1,
        config: Config = Config(),
        includeEyesOnlyPass: Bool = true
    ) -> Result<PreparedScenario, CalibrationError> {
        var user = SyntheticUser(seed: seed)
        let profileResult = user.calibrate(
            rig: scenario.rig,
            config: config,
            cameraUniqueID: "sim-camera",
            includeEyesOnlyPass: includeEyesOnlyPass,
            noise: scenario.noise,
            fps: scenario.fps
        )
        guard case .success(let profile) = profileResult else {
            if case .failure(let err) = profileResult {
                return .failure(err)
            }
            return .failure(.solverFailed)
        }

        let dt = 1.0 / max(scenario.fps, 1.0)
        let totalSteps = Int((scenario.duration / dt).rounded()) + 1

        var steps: [(TimeInterval, GazeEvent, InputActivity, Bool, Bool)] = []
        steps.reserveCapacity(totalSteps)

        var lastKeyDownAt: TimeInterval?
        var lastPointerMoveAt: TimeInterval?
        var lastPointerClickAt: TimeInterval?
        var isModifierHeld = false
        var isButtonDown = false
        var isPaused = false
        var isSessionActive = true
        var isSecureInput = false

        let sortedEvents = scenario.inputEvents.sorted { eventTime($0) < eventTime($1) }
        var eventCursor = 0

        for stepIdx in 0..<totalSteps {
            let t = Double(stepIdx) * dt
            while eventCursor < sortedEvents.count && eventTime(sortedEvents[eventCursor]) <= t + 1e-9 {
                let ev = sortedEvents[eventCursor]
                switch ev {
                case .keyDown(let at), .flagsChanged(let at):
                    lastKeyDownAt = at
                case .pointerMove(let at):
                    lastPointerMoveAt = at
                case .pointerClick(let at), .scroll(let at):
                    lastPointerClickAt = at
                case .pointerButton(let down, _):
                    isButtonDown = down
                case .modifierHeld(let held, _):
                    isModifierHeld = held
                case .paused(let p, _):
                    isPaused = p
                case .sessionActive(let active, _):
                    isSessionActive = active
                case .secureInput(let sec, _):
                    isSecureInput = sec
                }
                eventCursor += 1
            }

            let input = InputActivity(
                secondsSinceKeyboard: lastKeyDownAt.map { max(0, t - $0) } ?? 1000,
                secondsSincePointerMove: lastPointerMoveAt.map { max(0, t - $0) } ?? 1000,
                secondsSincePointerClick: lastPointerClickAt.map { max(0, t - $0) } ?? 1000,
                isModifierHeld: isModifierHeld,
                isPointerButtonDown: isButtonDown,
                isSecureInputEnabled: isSecureInput
            )

            let gazeEvent = generateGazeEvent(
                at: t,
                scenario: scenario,
                user: &user
            )

            steps.append((t, gazeEvent, input, isPaused, isSessionActive))
        }

        return .success(PreparedScenario(
            scenario: scenario,
            profile: profile,
            seed: seed,
            steps: steps
        ))
    }

    public static func run(
        _ scenario: Scenario,
        seed: UInt64 = 1,
        config: Config = Config(),
        snapshotMaxAge: TimeInterval = 0.2
    ) -> Result<ScenarioResult, CalibrationError> {
        switch prepare(scenario, seed: seed, config: config) {
        case .failure(let err):
            return .failure(err)
        case .success(let prepared):
            return .success(runPrepared(prepared, config: config, snapshotMaxAge: snapshotMaxAge))
        }
    }

    public static func runWithLadder(
        _ scenario: Scenario,
        seed: UInt64 = 1,
        config: Config = Config(),
        exposeWindowIDs: Bool = true,
        snapshotMaxAge: TimeInterval = 0.2
    ) async -> Result<ScenarioResult, CalibrationError> {
        switch prepare(scenario, seed: seed, config: config) {
        case .failure(let err):
            return .failure(err)
        case .success(let prepared):
            let clock = VirtualClock(startAt: prepared.steps.first?.timestamp ?? 0)
            let catalog = SimWindowCatalogService(
                windows: scenario.rig.windows,
                focusedWindowID: scenario.initialFocusedWindowID,
                clock: clock
            )
            let actuator = SimFocusActuator(catalog: catalog, exposeWindowIDs: exposeWindowIDs)
            let switcher = LadderFocusSwitcher(
                actuator: actuator,
                catalog: catalog,
                sleeper: VirtualSleeper(clock: nil)
            )
            let inputProvider = ManualInputActivityProvider()
            let sessionProvider = ManualSessionStateProvider(active: true)
            let topoService = SimDisplayTopologyService(topology: scenario.rig.topology)
            let gaze = SimGazeEstimator(
                prepared: prepared,
                clock: clock,
                inputProvider: inputProvider,
                sessionProvider: sessionProvider
            )
            let coordinator = FocusCoordinator(
                config: config,
                profile: prepared.profile,
                gazeEstimator: gaze,
                topologyService: topoService,
                windowCatalog: catalog,
                inputProvider: inputProvider,
                sessionProvider: sessionProvider,
                focusSwitcher: switcher,
                clock: clock,
                snapshotMaxAge: snapshotMaxAge
            )
            await coordinator.runUntilStreamFinishes()
            let log = await coordinator.log()

            var actualSwitches: [UInt32] = []
            var switchTimestamps: [(UInt32, TimeInterval)] = []
            for entry in log {
                switch entry.action {
                case .focus(let target):
                    if case .switched = entry.outcome {
                        actualSwitches.append(target.windowID)
                        switchTimestamps.append((target.windowID, entry.timestamp))
                    }
                case .none:
                    break
                }
            }

            return .success(ScenarioResult(
                scenarioName: scenario.name,
                seed: seed,
                profile: prepared.profile,
                decisionLog: log,
                actualSwitches: actualSwitches,
                expectedSwitches: scenario.expectedSwitches,
                switchTimestamps: switchTimestamps
            ))
        }
    }

    public static func runPrepared(
        _ prepared: PreparedScenario,
        config: Config = Config(),
        snapshotMaxAge: TimeInterval = 0.2
    ) -> ScenarioResult {
        let scenario = prepared.scenario
        let topology = scenario.rig.topology
        var windows = scenario.rig.windows.sorted { $0.zIndex < $1.zIndex }
        var focusedWindowID: UInt32? = scenario.initialFocusedWindowID
        var frontmostPID: Int32? = windows.first(where: { $0.windowID == scenario.initialFocusedWindowID })?.pid
        var frontmostBundleID: String? = windows.first(where: { $0.windowID == scenario.initialFocusedWindowID })?.bundleID

        func focusLocally(windowID: UInt32) {
            guard let target = windows.first(where: { $0.windowID == windowID }) else { return }
            windows.removeAll { $0.windowID == windowID }
            if let firstSamePID = windows.firstIndex(where: { $0.pid == target.pid }) {
                windows.insert(target, at: firstSamePID)
            } else {
                windows.insert(target, at: 0)
            }
            let pidWindows = windows.filter { $0.pid == target.pid }
            windows.removeAll { $0.pid == target.pid }
            windows.insert(contentsOf: pidWindows, at: 0)
            for idx in windows.indices {
                windows[idx].zIndex = idx
            }
            focusedWindowID = windowID
            frontmostPID = target.pid
            frontmostBundleID = target.bundleID
        }

        if let initID = focusedWindowID {
            focusLocally(windowID: initID)
        }

        func makeSnapshot(at t: TimeInterval) -> WindowSnapshot {
            WindowSnapshot(
                windows: windows,
                frontmostPID: frontmostPID,
                frontmostBundleID: frontmostBundleID,
                focusedWindowID: focusedWindowID,
                takenAt: t
            )
        }

        var pipeline = FocusPipeline(config: config, profile: prepared.profile)
        var cachedSnapshot = makeSnapshot(at: prepared.steps.first?.timestamp ?? 0)

        var decisionLog: [DecisionLogEntry] = []
        var actualSwitches: [UInt32] = []
        var switchTimestamps: [(UInt32, TimeInterval)] = []

        for step in prepared.steps {
            let now = step.timestamp
            if (now - cachedSnapshot.takenAt) >= snapshotMaxAge {
                cachedSnapshot = makeSnapshot(at: now)
            }

            let env = PipelineEnvironment(
                snapshot: cachedSnapshot,
                topology: topology,
                input: step.input,
                isPaused: step.isPaused,
                isSessionActive: step.isSessionActive,
                now: now
            )

            let output = pipeline.ingest(step.event, env: env)

            switch output.action {
            case .none:
                decisionLog.append(DecisionLogEntry(
                    timestamp: now,
                    action: .none,
                    veto: output.veto,
                    candidateWindowID: output.candidateWindowID,
                    outcome: nil
                ))

            case .focus(let target):
                let freshSnapshot = makeSnapshot(at: now)
                cachedSnapshot = freshSnapshot
                let confirmEnv = PipelineEnvironment(
                    snapshot: freshSnapshot,
                    topology: topology,
                    input: step.input,
                    isPaused: step.isPaused,
                    isSessionActive: step.isSessionActive,
                    now: now
                )
                guard pipeline.confirm(target, env: confirmEnv) else {
                    decisionLog.append(DecisionLogEntry(
                        timestamp: now,
                        action: .none,
                        veto: nil,
                        candidateWindowID: nil,
                        outcome: nil
                    ))
                    continue
                }

                let outcome: FocusOutcome
                if freshSnapshot.focusedWindowID == target.windowID {
                    outcome = .alreadyFocused
                } else {
                    let strategy: FocusStrategy = (freshSnapshot.frontmostPID == target.pid) ? .rungA : .rungB
                    focusLocally(windowID: target.windowID)
                    outcome = .switched(strategy)
                    actualSwitches.append(target.windowID)
                    switchTimestamps.append((target.windowID, now))
                }
                pipeline.recordOutcome(outcome, at: now)
                cachedSnapshot = makeSnapshot(at: now)
                decisionLog.append(DecisionLogEntry(
                    timestamp: now,
                    action: .focus(target),
                    veto: nil,
                    candidateWindowID: target.windowID,
                    outcome: outcome
                ))
            }
        }

        return ScenarioResult(
            scenarioName: scenario.name,
            seed: prepared.seed,
            profile: prepared.profile,
            decisionLog: decisionLog,
            actualSwitches: actualSwitches,
            expectedSwitches: scenario.expectedSwitches,
            switchTimestamps: switchTimestamps
        )
    }

    private static func generateGazeEvent(
        at t: TimeInterval,
        scenario: Scenario,
        user: inout SyntheticUser
    ) -> GazeEvent {
        let segment = scenario.segments.last { seg in
            t >= seg.startTime - 1e-9 && t <= seg.endTime + 1e-9
        }
        guard let segment else {
            return .noFace(t)
        }

        switch segment.target {
        case .noFace:
            return .noFace(t)
        case .window(let wid):
            guard let pt3 = scenario.rig.worldPoint(forWindowID: wid) else {
                return .noFace(t)
            }
            return .features(user.features(
                lookingAt: pt3,
                eyePositionMM: scenario.rig.eyePositionMM,
                timestamp: t,
                eyesOpen: segment.eyesOpen,
                faceCount: segment.faceCount,
                confidence: segment.confidence,
                noise: scenario.noise
            ))
        case .globalPoint(let gp):
            return .features(user.features(
                lookingAtGlobalPoint: gp,
                rig: scenario.rig,
                timestamp: t,
                eyesOpen: segment.eyesOpen,
                faceCount: segment.faceCount,
                confidence: segment.confidence,
                noise: scenario.noise
            ))
        case .sweep(let from, let to, let start, let end):
            let span = max(end - start, 1e-6)
            let alpha = CGFloat(min(max((t - start) / span, 0), 1))
            let pt = CGPoint(
                x: from.x + (to.x - from.x) * alpha,
                y: from.y + (to.y - from.y) * alpha
            )
            return .features(user.features(
                lookingAtGlobalPoint: pt,
                rig: scenario.rig,
                timestamp: t,
                eyesOpen: segment.eyesOpen,
                faceCount: segment.faceCount,
                confidence: segment.confidence,
                noise: scenario.noise
            ))
        case .worldPoint(let pt3):
            return .features(user.features(
                lookingAt: pt3,
                eyePositionMM: scenario.rig.eyePositionMM,
                timestamp: t,
                eyesOpen: segment.eyesOpen,
                faceCount: segment.faceCount,
                confidence: segment.confidence,
                noise: scenario.noise
            ))
        }
    }

    private static func eventTime(_ event: ScenarioInputEvent) -> TimeInterval {
        switch event {
        case .keyDown(let at),
             .flagsChanged(let at),
             .pointerMove(let at),
             .pointerClick(let at),
             .scroll(let at),
             .pointerButton(_, let at),
             .modifierHeld(_, let at),
             .paused(_, let at),
             .sessionActive(_, let at),
             .secureInput(_, let at):
            return at
        }
    }
}
