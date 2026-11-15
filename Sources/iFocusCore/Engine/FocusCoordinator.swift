import Foundation

public struct CoordinatorDiagnostics: Sendable, Equatable {
    public var statusPublishes: Int
    public var permissionChecks: Int
    public var estimatorStarts: Int
    public var logCount: Int

    public init(
        statusPublishes: Int,
        permissionChecks: Int,
        estimatorStarts: Int,
        logCount: Int
    ) {
        self.statusPublishes = statusPublishes
        self.permissionChecks = permissionChecks
        self.estimatorStarts = estimatorStarts
        self.logCount = logCount
    }
}

public struct DecisionLogEntry: Sendable, Equatable {
    public var timestamp: TimeInterval
    public var action: EngineAction
    public var veto: SafetyVeto?
    public var candidateWindowID: UInt32?
    public var outcome: FocusOutcome?

    public init(
        timestamp: TimeInterval,
        action: EngineAction,
        veto: SafetyVeto?,
        candidateWindowID: UInt32?,
        outcome: FocusOutcome?
    ) {
        self.timestamp = timestamp
        self.action = action
        self.veto = veto
        self.candidateWindowID = candidateWindowID
        self.outcome = outcome
    }
}

public actor FocusCoordinator {
    private struct RingBuffer {
        private var storage: [DecisionLogEntry?]
        private var head: Int = 0
        private(set) var count: Int = 0
        let capacity: Int

        init(capacity: Int) {
            let cap = max(capacity, 1)
            self.capacity = cap
            self.storage = Array(repeating: nil, count: cap)
        }

        mutating func append(_ entry: DecisionLogEntry) {
            if count < capacity {
                let idx = (head + count) % capacity
                storage[idx] = entry
                count += 1
            } else {
                storage[head] = entry
                head = (head + 1) % capacity
            }
        }

        func entries() -> [DecisionLogEntry] {
            guard count > 0 else { return [] }
            var result: [DecisionLogEntry] = []
            result.reserveCapacity(count)
            for offset in 0..<count {
                let idx = (head + offset) % capacity
                if let item = storage[idx] {
                    result.append(item)
                }
            }
            return result
        }
    }

    private struct StatusKey: Equatable {
        var state: CoordinatorStateKind
        var lastVeto: SafetyVeto?
        var failureCount: Int
        var detail: String?
    }

    private enum RunExit {
        case stopped
        case streamEnded
        case interrupted(String)
        case startFailed(String)
    }

    private var pipeline: FocusPipeline
    private let gazeEstimator: any GazeEstimator
    private let topologyService: any DisplayTopologyService
    private let windowCatalog: any WindowCatalogService
    private let inputProvider: any InputActivityProvider
    private let sessionProvider: any SessionStateProvider
    private let focusSwitcher: any FocusSwitcher
    private let clock: any MonotonicClock
    private let snapshotMaxAge: TimeInterval
    private let permissionChecker: @Sendable () -> (camera: Bool, accessibility: Bool)
    private let retrySleeper: (any Sleeper)?
    private let permissionCacheTTL: TimeInterval

    private var isPaused: Bool = false
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var runTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopCounter: UInt64 = 0
    private var cachedSnapshot: WindowSnapshot?
    private var cachedTopology: DisplayTopology = .empty
    private var decisionLog: RingBuffer

    private var cachedPermissions: (value: (camera: Bool, accessibility: Bool), fetchedAt: TimeInterval)?
    private var lastPublishedKey: StatusKey?
    private var lastPublishedStatus: CoordinatorStatus?

    private var statusPublishesCount: Int = 0
    private var permissionChecksCount: Int = 0
    private var estimatorStartsCount: Int = 0

    private var eventContinuations: [UUID: AsyncStream<CoordinatorEvent>.Continuation] = [:]

    public init(
        config: Config,
        profile: CalibrationProfile?,
        gazeEstimator: any GazeEstimator,
        topologyService: any DisplayTopologyService,
        windowCatalog: any WindowCatalogService,
        inputProvider: any InputActivityProvider,
        sessionProvider: any SessionStateProvider,
        focusSwitcher: any FocusSwitcher,
        clock: any MonotonicClock,
        snapshotMaxAge: TimeInterval = 0.2,
        permissionChecker: @escaping @Sendable () -> (camera: Bool, accessibility: Bool) = { (true, true) },
        maxDecisionLogEntries: Int = 4096,
        retrySleeper: (any Sleeper)? = nil,
        permissionCacheTTL: TimeInterval = 1.0
    ) {
        self.pipeline = FocusPipeline(config: config, profile: profile)
        self.gazeEstimator = gazeEstimator
        self.topologyService = topologyService
        self.windowCatalog = windowCatalog
        self.inputProvider = inputProvider
        self.sessionProvider = sessionProvider
        self.focusSwitcher = focusSwitcher
        self.clock = clock
        self.snapshotMaxAge = snapshotMaxAge
        self.permissionChecker = permissionChecker
        self.decisionLog = RingBuffer(capacity: maxDecisionLogEntries)
        self.retrySleeper = retrySleeper
        self.permissionCacheTTL = max(permissionCacheTTL, 0)
    }

    private func isLive(_ g: UInt64) -> Bool {
        activeGeneration == g
    }

    public func events() -> AsyncStream<CoordinatorEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: CoordinatorEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        eventContinuations[id] = continuation
        if let lastPublishedStatus {
            continuation.yield(.status(lastPublishedStatus))
        }
        return stream
    }

    private func removeContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
        cachedPermissions = nil
        publishStatus(lastVeto: paused ? .paused : nil)
    }

    public func togglePaused() -> Bool {
        isPaused.toggle()
        cachedPermissions = nil
        publishStatus(lastVeto: isPaused ? .paused : nil)
        return isPaused
    }

    public func paused() -> Bool {
        isPaused
    }

    public func updateConfig(_ config: Config) {
        pipeline.updateConfig(config)
    }

    public func updateProfile(_ profile: CalibrationProfile?) {
        pipeline.updateProfile(profile)
        cachedPermissions = nil
        publishStatus(lastVeto: nil)
    }

    public func log() -> [DecisionLogEntry] {
        decisionLog.entries()
    }

    public func failureCount() -> Int {
        pipeline.failureCount
    }

    public func diagnostics() -> CoordinatorDiagnostics {
        CoordinatorDiagnostics(
            statusPublishes: statusPublishesCount,
            permissionChecks: permissionChecksCount,
            estimatorStarts: estimatorStartsCount,
            logCount: decisionLog.count
        )
    }

    public func start() {
        guard activeGeneration == nil else { return }
        generation &+= 1
        let g = generation
        let previousStop = stopTask
        activeGeneration = g
        cachedPermissions = nil
        runTask = Task {
            await supervise(generation: g, waitForStop: previousStop)
        }
    }

    public func stop() async {
        activeGeneration = nil
        let task = runTask
        runTask = nil
        task?.cancel()

        let previousStop = stopTask
        stopCounter &+= 1
        let myStopID = stopCounter
        let cleanup = Task { [gazeEstimator] in
            await previousStop?.value
            await gazeEstimator.stop()
            await task?.value
        }
        stopTask = cleanup
        await cleanup.value
        if stopCounter == myStopID {
            stopTask = nil
        }
    }

    public func runUntilStreamFinishes() async {
        if let pendingStop = stopTask {
            await pendingStop.value
        }
        generation &+= 1
        let g = generation
        activeGeneration = g
        cachedPermissions = nil
        let (exitReason, _) = await runOnce(generation: g)
        if case .interrupted(let reason) = exitReason {
            publishErrorStatus(detail: reason)
        } else if case .startFailed(let reason) = exitReason {
            publishErrorStatus(detail: reason)
        }
        if activeGeneration == g {
            activeGeneration = nil
        }
    }

    private func supervise(generation g: UInt64, waitForStop: Task<Void, Never>?) async {
        if let waitForStop {
            await waitForStop.value
        }
        guard isLive(g) && !Task.isCancelled else { return }

        var backoff: TimeInterval = 5.0

        while isLive(g) && !Task.isCancelled {
            if !sessionProvider.isSessionActive() {
                publishStatus(lastVeto: .sessionInactive)
                guard let retrySleeper else {
                    if activeGeneration == g { activeGeneration = nil }
                    return
                }
                await retrySleeper.sleep(seconds: backoff)
                if !isLive(g) || Task.isCancelled { return }
                continue
            }

            let (exitReason, gotDataEvent) = await runOnce(generation: g)
            if gotDataEvent {
                backoff = 5.0
            }

            switch exitReason {
            case .stopped:
                return
            case .streamEnded:
                guard isLive(g) && !Task.isCancelled else { return }
                publishErrorStatus(detail: "Camera stream ended")
            case .interrupted(let reason), .startFailed(let reason):
                guard isLive(g) && !Task.isCancelled else { return }
                publishErrorStatus(detail: reason)
            }

            guard let retrySleeper else {
                if activeGeneration == g { activeGeneration = nil }
                return
            }
            await retrySleeper.sleep(seconds: backoff)
            backoff = min(backoff * 2.0, 60.0)
        }
    }

    private func runOnce(generation g: UInt64) async -> (RunExit, Bool) {
        guard isLive(g) && !Task.isCancelled else { return (.stopped, false) }

        let topo = await topologyService.current()
        guard isLive(g) && !Task.isCancelled else { return (.stopped, false) }
        cachedTopology = topo

        let snap = await windowCatalog.snapshot()
        guard isLive(g) && !Task.isCancelled else { return (.stopped, false) }
        cachedSnapshot = snap

        publishStatus(lastVeto: nil)

        let stream: AsyncStream<GazeEvent>
        do {
            stream = try await gazeEstimator.start()
            estimatorStartsCount += 1
        } catch {
            return (.startFailed("\(error)"), false)
        }

        if !isLive(g) || Task.isCancelled {
            if activeGeneration == nil {
                await gazeEstimator.stop()
            }
            return (.stopped, false)
        }

        var gotDataEvent = false
        for await event in stream {
            if !isLive(g) || Task.isCancelled {
                if activeGeneration == nil {
                    await gazeEstimator.stop()
                }
                return (.stopped, gotDataEvent)
            }

            if case .interrupted(let reason) = event {
                await processSingleEvent(event, generation: g)
                await gazeEstimator.stop()
                return (.interrupted(reason), gotDataEvent)
            }

            gotDataEvent = true
            await processSingleEvent(event, generation: g)
        }

        if !isLive(g) || Task.isCancelled {
            return (.stopped, gotDataEvent)
        }
        return (.streamEnded, gotDataEvent)
    }

    private func processSingleEvent(_ event: GazeEvent, generation g: UInt64) async {
        guard isLive(g) else { return }
        let now = clock.now()
        if cachedSnapshot == nil || (now - (cachedSnapshot?.takenAt ?? -Double.infinity)) >= snapshotMaxAge {
            let newTopo = await topologyService.current()
            guard isLive(g) else { return }
            let newSnap = await windowCatalog.snapshot()
            guard isLive(g) else { return }
            cachedTopology = newTopo
            cachedSnapshot = newSnap
        }

        let snapshot = cachedSnapshot ?? .empty(at: now)
        let input = inputProvider.sample()
        let sessionActive = sessionProvider.isSessionActive()

        let env = PipelineEnvironment(
            snapshot: snapshot,
            topology: cachedTopology,
            input: input,
            isPaused: isPaused,
            isSessionActive: sessionActive,
            now: now
        )

        let output = pipeline.ingest(event, env: env)

        switch output.action {
        case .none:
            decisionLog.append(DecisionLogEntry(
                timestamp: now,
                action: .none,
                veto: output.veto,
                candidateWindowID: output.candidateWindowID,
                outcome: nil
            ))
            publishStatus(lastVeto: output.veto)

        case .focus(let target):
            let freshSnapshot = await windowCatalog.snapshot()
            guard isLive(g) else { return }
            let freshTopology = await topologyService.current()
            guard isLive(g) else { return }
            cachedSnapshot = freshSnapshot
            cachedTopology = freshTopology
            let freshNow = clock.now()
            let freshInput = inputProvider.sample()
            let freshSession = sessionProvider.isSessionActive()
            let confirmEnv = PipelineEnvironment(
                snapshot: freshSnapshot,
                topology: freshTopology,
                input: freshInput,
                isPaused: isPaused,
                isSessionActive: freshSession,
                now: freshNow
            )

            guard pipeline.confirm(target, env: confirmEnv) else {
                decisionLog.append(DecisionLogEntry(
                    timestamp: freshNow,
                    action: .none,
                    veto: nil,
                    candidateWindowID: nil,
                    outcome: nil
                ))
                return
            }

            guard isLive(g) else { return }
            let outcome = await focusSwitcher.focus(target)
            pipeline.recordOutcome(outcome, at: clock.now())
            cachedSnapshot = await windowCatalog.snapshot()
            decisionLog.append(DecisionLogEntry(
                timestamp: freshNow,
                action: .focus(target),
                veto: nil,
                candidateWindowID: target.windowID,
                outcome: outcome
            ))

            switch outcome {
            case .switched(let strategy):
                publish(.switched(target, strategy))
            case .failed(let failure):
                publish(.failed(target, failure))
            case .alreadyFocused:
                break
            }
            publishStatus(lastVeto: nil)
        }
    }

    private func currentPermissions(at now: TimeInterval) -> (camera: Bool, accessibility: Bool) {
        if let cached = cachedPermissions, (now - cached.fetchedAt) < permissionCacheTTL {
            return cached.value
        }
        permissionChecksCount += 1
        let value = permissionChecker()
        cachedPermissions = (value, now)
        return value
    }

    private func publishStatus(lastVeto: SafetyVeto?) {
        let now = clock.now()
        let perms = currentPermissions(at: now)
        let state: CoordinatorStateKind
        if !perms.camera || !perms.accessibility {
            state = .needsPermission
        } else if isPaused {
            state = .paused
        } else if pipeline.profile == nil {
            state = .needsCalibration
        } else {
            state = .running
        }

        let detail: String?
        if lastVeto == .sourceNotAllowed,
           let snap = cachedSnapshot,
           let prompt = WindowHitTester.securityPrompt(in: snap) {
            detail = "System prompt on screen: \(prompt.bundleID ?? "unknown")"
        } else {
            detail = nil
        }

        let status = CoordinatorStatus(
            state: state,
            lastVeto: lastVeto,
            failureCount: pipeline.failureCount,
            candidateWindowID: nil,
            dwellProgress: 0,
            detail: detail
        )
        emitStatusIfChanged(status)
    }

    private func publishErrorStatus(detail: String) {
        let status = CoordinatorStatus(
            state: .error,
            lastVeto: nil,
            failureCount: pipeline.failureCount,
            candidateWindowID: nil,
            dwellProgress: 0,
            detail: detail
        )
        emitStatusIfChanged(status)
    }

    private func emitStatusIfChanged(_ status: CoordinatorStatus) {
        let key = StatusKey(
            state: status.state,
            lastVeto: status.lastVeto,
            failureCount: status.failureCount,
            detail: status.detail
        )
        guard key != lastPublishedKey else { return }
        lastPublishedKey = key
        lastPublishedStatus = status
        statusPublishesCount += 1
        publish(.status(status))
    }

    private func publish(_ event: CoordinatorEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}
