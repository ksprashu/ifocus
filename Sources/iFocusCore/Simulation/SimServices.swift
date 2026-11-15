import CoreGraphics
import Foundation

private final class LockedBox<Value: Sendable>: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

public final class VirtualClock: MonotonicClock, Sendable {
    private let box: LockedBox<TimeInterval>

    public init(startAt: TimeInterval = 0) {
        self.box = LockedBox(startAt)
    }

    public func now() -> TimeInterval {
        box.get()
    }

    public func set(_ time: TimeInterval) {
        box.set(time)
    }

    public func advance(by delta: TimeInterval) {
        box.withLock { $0 += delta }
    }
}

public final class VirtualSleeper: Sleeper, Sendable {
    private let clock: VirtualClock?
    private let recordedSleeps = LockedBox<[TimeInterval]>([])

    public init(clock: VirtualClock? = nil) {
        self.clock = clock
    }

    public func sleep(seconds: TimeInterval) async {
        recordedSleeps.withLock { $0.append(seconds) }
        clock?.advance(by: seconds)
    }

    public func sleeps() -> [TimeInterval] {
        recordedSleeps.get()
    }
}

public final class ManualInputActivityProvider: InputActivityProvider, Sendable {
    private let box: LockedBox<InputActivity>

    public init(initial: InputActivity = InputActivity()) {
        self.box = LockedBox(initial)
    }

    public func sample() -> InputActivity {
        box.get()
    }

    public func update(_ value: InputActivity) {
        box.set(value)
    }

    public func mutate(_ body: (inout InputActivity) -> Void) {
        box.withLock(body)
    }
}

public final class ManualSessionStateProvider: SessionStateProvider, Sendable {
    private let box: LockedBox<Bool>

    public init(active: Bool = true) {
        self.box = LockedBox(active)
    }

    public func isSessionActive() -> Bool {
        box.get()
    }

    public func setActive(_ active: Bool) {
        box.set(active)
    }
}

public actor SimDisplayTopologyService: DisplayTopologyService {
    private var topology: DisplayTopology
    private let continuations = LockedBox<[UUID: AsyncStream<DisplayTopology>.Continuation]>([:])

    public init(topology: DisplayTopology) {
        self.topology = topology
    }

    public func current() async -> DisplayTopology {
        topology
    }

    public func setTopology(_ newTopology: DisplayTopology) {
        topology = newTopology
        let snapshot = continuations.get().values
        for cont in snapshot {
            cont.yield(newTopology)
        }
    }

    public nonisolated func updates() -> AsyncStream<DisplayTopology> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: DisplayTopology.self, bufferingPolicy: .bufferingNewest(8))
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        continuations.withLock { $0[id] = continuation }
        return stream
    }
}

public actor SimWindowCatalogService: WindowCatalogService {
    private var windows: [WindowDescriptor]
    private var frontmostPID: Int32?
    private var frontmostBundleID: String?
    private var focusedWindowID: UInt32?
    private var pendingActivation: (pid: Int32, effectiveAt: TimeInterval)?
    private let clock: any MonotonicClock

    public init(
        windows: [WindowDescriptor],
        focusedWindowID: UInt32?,
        clock: any MonotonicClock = VirtualClock()
    ) {
        let sorted = windows.sorted { $0.zIndex < $1.zIndex }
        let resolvedPID: Int32?
        let resolvedBundle: String?
        if let focused = focusedWindowID.flatMap({ id in sorted.first(where: { $0.windowID == id }) }) {
            resolvedPID = focused.pid
            resolvedBundle = focused.bundleID
        } else {
            resolvedPID = sorted.first?.pid
            resolvedBundle = sorted.first?.bundleID
        }
        self.frontmostPID = resolvedPID
        self.frontmostBundleID = resolvedBundle
        self.focusedWindowID = focusedWindowID
        self.clock = clock
        self.windows = Self.orderedWindows(sorted, bringingFrontmostPID: resolvedPID, focusedWindowID: focusedWindowID)
    }

    private static func orderedWindows(
        _ input: [WindowDescriptor],
        bringingFrontmostPID pid: Int32?,
        focusedWindowID: UInt32?
    ) -> [WindowDescriptor] {
        var copy = input
        if let focusedWindowID, let pid,
           let idx = copy.firstIndex(where: { $0.windowID == focusedWindowID && $0.pid == pid }) {
            let target = copy.remove(at: idx)
            if let firstSame = copy.firstIndex(where: { $0.pid == pid }) {
                copy.insert(target, at: firstSame)
            } else {
                copy.insert(target, at: 0)
            }
        }
        if let pid {
            let appWins = copy.filter { $0.pid == pid }
            copy.removeAll { $0.pid == pid }
            copy.insert(contentsOf: appWins, at: 0)
        }
        for i in copy.indices {
            copy[i].zIndex = i
        }
        return copy
    }

    public func snapshot() async -> WindowSnapshot {
        flushPendingActivation()
        return WindowSnapshot(
            windows: windows,
            frontmostPID: frontmostPID,
            frontmostBundleID: frontmostBundleID,
            focusedWindowID: focusedWindowID,
            takenAt: clock.now()
        )
    }

    public func windows(of pid: Int32) -> [WindowDescriptor] {
        flushPendingActivation()
        return windows.filter { $0.pid == pid }.sorted { $0.zIndex < $1.zIndex }
    }

    public func scheduleAppFrontmost(pid: Int32, after delay: TimeInterval) {
        if delay <= 0 {
            pendingActivation = nil
            setAppFrontmost(pid: pid)
        } else {
            pendingActivation = (pid, clock.now() + delay)
        }
    }

    private func flushPendingActivation() {
        guard let pending = pendingActivation, clock.now() + 1e-9 >= pending.effectiveAt else {
            return
        }
        pendingActivation = nil
        setAppFrontmost(pid: pending.pid)
    }

    public func raiseWindowWithinApp(id: UInt32, pid: Int32) {
        guard let idx = windows.firstIndex(where: { $0.windowID == id && $0.pid == pid }) else { return }
        let target = windows.remove(at: idx)
        if let firstOfPID = windows.firstIndex(where: { $0.pid == pid }) {
            windows.insert(target, at: firstOfPID)
        } else {
            windows.insert(target, at: 0)
        }
        if frontmostPID == pid {
            focusedWindowID = id
        }
        recomputeZIndices()
    }

    public func setAppFrontmost(pid: Int32) {
        let appWindows = windows.filter { $0.pid == pid }
        guard let top = appWindows.first else { return }
        windows.removeAll { $0.pid == pid }
        windows.insert(contentsOf: appWindows, at: 0)
        frontmostPID = pid
        frontmostBundleID = top.bundleID
        focusedWindowID = top.windowID
        recomputeZIndices()
    }

    public func focusWindow(id: UInt32) {
        guard let win = windows.first(where: { $0.windowID == id }) else { return }
        raiseWindowWithinApp(id: id, pid: win.pid)
        setAppFrontmost(pid: win.pid)
    }

    public func removeWindow(id: UInt32) {
        windows.removeAll { $0.windowID == id }
        if focusedWindowID == id {
            focusedWindowID = windows.first?.windowID
            frontmostPID = windows.first?.pid
            frontmostBundleID = windows.first?.bundleID
        }
        recomputeZIndices()
    }

    public func setWindows(_ newWindows: [WindowDescriptor], focusedWindowID: UInt32?) {
        self.windows = newWindows.sorted { $0.zIndex < $1.zIndex }
        self.focusedWindowID = focusedWindowID
        if let focused = focusedWindowID.flatMap({ id in newWindows.first(where: { $0.windowID == id }) }) {
            self.frontmostPID = focused.pid
            self.frontmostBundleID = focused.bundleID
        } else {
            self.frontmostPID = newWindows.first?.pid
            self.frontmostBundleID = newWindows.first?.bundleID
        }
        self.windows = Self.orderedWindows(newWindows.sorted { $0.zIndex < $1.zIndex }, bringingFrontmostPID: self.frontmostPID, focusedWindowID: focusedWindowID)
    }

    private func recomputeZIndices() {
        for i in windows.indices {
            windows[i].zIndex = i
        }
    }
}

public actor SimFocusActuator: FocusActuator {
    public struct PerformCall: Sendable, Equatable {
        public var step: FocusStep
        public var pid: Int32
        public var candidate: AXWindowCandidate
    }

    private let catalog: SimWindowCatalogService
    public var exposeWindowIDs: Bool
    public var allowRaise: Bool
    public var allowAXFrontmost: Bool
    public var allowActivateApp: Bool
    public var failAllSwitches: Bool
    public var wrongWindowIDToRaise: UInt32?
    public var wrongWindowOnlyForTargetID: UInt32?
    public var keyWindowOverride: KeyWindowCheck?
    public var forcedStepResult: FocusStepResult?
    public var reorderAXOrderAfterRungA: Bool
    public var rejectIdentityMismatch: Bool
    public var ignoreRaiseWhileAppInBackground: Bool
    public var activationLatencySeconds: TimeInterval
    public private(set) var windowsCallCount: Int = 0
    public private(set) var performCalls: [PerformCall] = []

    private var customOrderByPID: [Int32: [UInt32]] = [:]

    public init(
        catalog: SimWindowCatalogService,
        exposeWindowIDs: Bool = true,
        allowRaise: Bool = true,
        allowAXFrontmost: Bool = true,
        allowActivateApp: Bool = true,
        failAllSwitches: Bool = false,
        wrongWindowIDToRaise: UInt32? = nil,
        wrongWindowOnlyForTargetID: UInt32? = nil,
        keyWindowOverride: KeyWindowCheck? = nil,
        forcedStepResult: FocusStepResult? = nil,
        reorderAXOrderAfterRungA: Bool = false,
        rejectIdentityMismatch: Bool = false,
        ignoreRaiseWhileAppInBackground: Bool = false,
        activationLatencySeconds: TimeInterval = 0
    ) {
        self.catalog = catalog
        self.exposeWindowIDs = exposeWindowIDs
        self.allowRaise = allowRaise
        self.allowAXFrontmost = allowAXFrontmost
        self.allowActivateApp = allowActivateApp
        self.failAllSwitches = failAllSwitches
        self.wrongWindowIDToRaise = wrongWindowIDToRaise
        self.wrongWindowOnlyForTargetID = wrongWindowOnlyForTargetID
        self.keyWindowOverride = keyWindowOverride
        self.forcedStepResult = forcedStepResult
        self.reorderAXOrderAfterRungA = reorderAXOrderAfterRungA
        self.rejectIdentityMismatch = rejectIdentityMismatch
        self.ignoreRaiseWhileAppInBackground = ignoreRaiseWhileAppInBackground
        self.activationLatencySeconds = activationLatencySeconds
    }

    public func setConfiguration(
        exposeWindowIDs: Bool? = nil,
        allowRaise: Bool? = nil,
        allowAXFrontmost: Bool? = nil,
        allowActivateApp: Bool? = nil,
        failAllSwitches: Bool? = nil,
        wrongWindowIDToRaise: UInt32?? = nil,
        wrongWindowOnlyForTargetID: UInt32?? = nil,
        keyWindowOverride: KeyWindowCheck?? = nil,
        forcedStepResult: FocusStepResult?? = nil,
        reorderAXOrderAfterRungA: Bool? = nil,
        rejectIdentityMismatch: Bool? = nil,
        ignoreRaiseWhileAppInBackground: Bool? = nil,
        activationLatencySeconds: TimeInterval? = nil
    ) {
        if let v = exposeWindowIDs { self.exposeWindowIDs = v }
        if let v = allowRaise { self.allowRaise = v }
        if let v = allowAXFrontmost { self.allowAXFrontmost = v }
        if let v = allowActivateApp { self.allowActivateApp = v }
        if let v = failAllSwitches { self.failAllSwitches = v }
        if let v = wrongWindowIDToRaise { self.wrongWindowIDToRaise = v }
        if let v = wrongWindowOnlyForTargetID { self.wrongWindowOnlyForTargetID = v }
        if let v = keyWindowOverride { self.keyWindowOverride = v }
        if let v = forcedStepResult { self.forcedStepResult = v }
        if let v = reorderAXOrderAfterRungA { self.reorderAXOrderAfterRungA = v }
        if let v = rejectIdentityMismatch { self.rejectIdentityMismatch = v }
        if let v = ignoreRaiseWhileAppInBackground { self.ignoreRaiseWhileAppInBackground = v }
        if let v = activationLatencySeconds { self.activationLatencySeconds = v }
    }

    public func windows(of pid: Int32) async -> [AXWindowCandidate] {
        windowsCallCount += 1
        var appWindows = await catalog.windows(of: pid)
        if let customOrder = customOrderByPID[pid] {
            appWindows.sort { a, b in
                let ia = customOrder.firstIndex(of: a.windowID) ?? Int.max
                let ib = customOrder.firstIndex(of: b.windowID) ?? Int.max
                return ia < ib
            }
        }
        return appWindows.enumerated().map { idx, win in
            AXWindowCandidate(
                index: idx,
                windowID: exposeWindowIDs ? win.windowID : nil,
                frame: win.bounds,
                isMinimized: false,
                subrole: "AXStandardWindow"
            )
        }
    }

    public func keyWindowCheck(pid: Int32, expected: AXWindowCandidate) async -> KeyWindowCheck {
        if let override = keyWindowOverride {
            return override
        }
        let snap = await catalog.snapshot()
        guard let focusedID = snap.focusedWindowID, snap.frontmostPID == pid else {
            return .differs
        }
        if let expectedID = expected.windowID {
            return focusedID == expectedID ? .matches : .differs
        }
        if let expectedFrame = expected.frame, let focusedWin = snap.window(id: focusedID) {
            return (focusedWin.pid == pid && AXWindowMatcher.edgesWithin(focusedWin.bounds, expectedFrame, tolerance: 2.0))
                ? .matches
                : .differs
        }
        return .differs
    }

    public func perform(_ step: FocusStep, pid: Int32, window: AXWindowCandidate) async -> FocusStepResult {
        performCalls.append(PerformCall(step: step, pid: pid, candidate: window))

        if let forced = forcedStepResult {
            return forced
        }

        if rejectIdentityMismatch {
            return .staleCandidate
        }

        let currentList = await windows(of: pid)
        guard window.index >= 0, window.index < currentList.count else {
            return .staleCandidate
        }
        let currentAtIdx = currentList[window.index]
        if let expectedID = window.windowID {
            if currentAtIdx.windowID != expectedID {
                return .staleCandidate
            }
        } else if let expectedFrame = window.frame, let currentFrame = currentAtIdx.frame {
            if !AXWindowMatcher.edgesWithin(currentFrame, expectedFrame, tolerance: 2.0) {
                return .staleCandidate
            }
        } else {
            return .staleCandidate
        }

        let allAppWindows = await catalog.windows(of: pid)
        let targetWin: WindowDescriptor?
        if let wid = window.windowID {
            targetWin = allAppWindows.first { $0.windowID == wid }
        } else if let frame = window.frame {
            targetWin = allAppWindows.first { AXWindowMatcher.edgesWithin($0.bounds, frame, tolerance: 2.0) }
        } else {
            targetWin = nil
        }

        guard let target = targetWin else {
            return .staleCandidate
        }

        if failAllSwitches {
            return .performed
        }

        if let wrongID = wrongWindowIDToRaise {
            if wrongWindowOnlyForTargetID == nil || wrongWindowOnlyForTargetID == target.windowID {
                await catalog.focusWindow(id: wrongID)
                return .performed
            }
        }

        let snapshot = await catalog.snapshot()
        switch step {
        case .raiseAndMakeMain:
            if reorderAXOrderAfterRungA {
                let rotated = Array(allAppWindows.map(\.windowID).reversed())
                customOrderByPID[pid] = rotated
            }
            if allowRaise && !(ignoreRaiseWhileAppInBackground && snapshot.frontmostPID != pid) {
                await catalog.raiseWindowWithinApp(id: target.windowID, pid: pid)
            }
        case .setAppFrontmost:
            if allowAXFrontmost {
                await catalog.scheduleAppFrontmost(pid: pid, after: activationLatencySeconds)
            }
        case .activateApp:
            if allowActivateApp {
                await catalog.scheduleAppFrontmost(pid: pid, after: activationLatencySeconds)
            }
        }
        return .performed
    }
}

public final class SimFocusSwitcher: FocusSwitcher, Sendable {
    private let outcomeBox: LockedBox<FocusOutcome>
    private let callsBox = LockedBox<[WindowDescriptor]>([])

    public init(outcome: FocusOutcome = .switched(.rungA)) {
        self.outcomeBox = LockedBox(outcome)
    }

    public func setOutcome(_ outcome: FocusOutcome) {
        outcomeBox.set(outcome)
    }

    public func focus(_ target: WindowDescriptor) async -> FocusOutcome {
        callsBox.withLock { $0.append(target) }
        return outcomeBox.get()
    }

    public func recordedTargets() -> [WindowDescriptor] {
        callsBox.get()
    }
}

public actor SimGazeEstimator: GazeEstimator {
    private let stepProducer: @Sendable () async -> GazeEvent?
    private var running = false

    public init(events: [GazeEvent]) {
        let indexBox = LockedBox(0)
        self.stepProducer = {
            indexBox.withLock { idx in
                guard idx < events.count else { return nil }
                let ev = events[idx]
                idx += 1
                return ev
            }
        }
    }

    public init(
        prepared: PreparedScenario,
        clock: VirtualClock,
        inputProvider: ManualInputActivityProvider,
        sessionProvider: ManualSessionStateProvider
    ) {
        let indexBox = LockedBox(0)
        self.stepProducer = {
            let nextStep = indexBox.withLock { idx -> (timestamp: TimeInterval, event: GazeEvent, input: InputActivity, isPaused: Bool, isSessionActive: Bool)? in
                guard idx < prepared.steps.count else { return nil }
                let step = prepared.steps[idx]
                idx += 1
                return step
            }
            guard let step = nextStep else { return nil }
            clock.set(step.timestamp)
            inputProvider.update(step.input)
            sessionProvider.setActive(step.isSessionActive)
            return step.event
        }
    }

    public init(stepProducer: @escaping @Sendable () async -> GazeEvent?) {
        self.stepProducer = stepProducer
    }

    public func start() async throws -> AsyncStream<GazeEvent> {
        running = true
        let producer = stepProducer
        return AsyncStream<GazeEvent> {
            await producer()
        }
    }

    public func stop() async {
        running = false
    }
}
