import Foundation
@testable import iFocusCore

extension Config {
    /// Round 1 and 2 mechanics fixture: allowlist scope and short v1 timings.
    static var v1Mechanics: Config {
        Config(
            dwellCrossDisplaySeconds: 0.30,
            dwellSameDisplaySeconds: 0.45,
            typingLockSeconds: 1.0,
            pointerMoveLockSeconds: 0.8,
            pointerClickLockSeconds: 1.5,
            focusScope: .allowlist
        )
    }
}

actor AsyncSignalGate {
    private var isOpen: Bool
    private var continuations: [AsyncStream<Void>.Continuation] = []

    init(initiallyOpen: Bool = false) {
        self.isOpen = initiallyOpen
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for c in pending {
            c.finish()
        }
    }

    func wait() async {
        if isOpen || Task.isCancelled {
            return
        }
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        continuations.append(cont)
        await withTaskCancellationHandler {
            for await _ in stream { break }
        } onCancel: {
            cont.finish()
        }
    }
}

actor RecordingEstimator: GazeEstimator {
    typealias StreamHandler = @Sendable (Int, AsyncStream<GazeEvent>.Continuation) async -> Void

    private(set) var startCount: Int = 0
    private(set) var stopCount: Int = 0
    private(set) var maxLiveStreams: Int = 0
    private var liveStreamIDs: Set<UInt64> = []
    private var continuations: [UInt64: AsyncStream<GazeEvent>.Continuation] = [:]
    private var nextStreamID: UInt64 = 0
    private let stopDelayNanoseconds: UInt64
    private let handlers: [StreamHandler]
    private var startWaiters: [(target: Int, cont: AsyncStream<Void>.Continuation)] = []
    private var stopEnteredWaiters: [AsyncStream<Void>.Continuation] = []

    var isLive: Bool {
        !liveStreamIDs.isEmpty
    }

    var liveStreams: Int {
        liveStreamIDs.count
    }

    init(stopDelayNanoseconds: UInt64 = 0, handlers: [StreamHandler] = []) {
        self.stopDelayNanoseconds = stopDelayNanoseconds
        self.handlers = handlers
    }

    func start() async throws -> AsyncStream<GazeEvent> {
        startCount += 1
        let callIndex = startCount
        nextStreamID &+= 1
        let streamID = nextStreamID

        let (stream, continuation) = AsyncStream.makeStream(of: GazeEvent.self, bufferingPolicy: .unbounded)
        liveStreamIDs.insert(streamID)
        continuations[streamID] = continuation
        if liveStreamIDs.count > maxLiveStreams {
            maxLiveStreams = liveStreamIDs.count
        }

        var remainingWaiters: [(target: Int, cont: AsyncStream<Void>.Continuation)] = []
        for waiter in startWaiters {
            if startCount >= waiter.target {
                waiter.cont.finish()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        startWaiters = remainingWaiters

        if callIndex - 1 < handlers.count {
            let handler = handlers[callIndex - 1]
            Task {
                await handler(callIndex, continuation)
                self.markStreamClosed(id: streamID)
            }
        }

        return stream
    }

    func stop() async {
        stopCount += 1
        let waiters = stopEnteredWaiters
        stopEnteredWaiters.removeAll()
        for w in waiters {
            w.finish()
        }

        let toClose = continuations
        if stopDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: stopDelayNanoseconds)
        }
        for (id, cont) in toClose {
            cont.finish()
            liveStreamIDs.remove(id)
            continuations.removeValue(forKey: id)
        }
    }

    private func markStreamClosed(id: UInt64) {
        liveStreamIDs.remove(id)
        continuations.removeValue(forKey: id)
    }

    func waitForStartCount(_ target: Int) async {
        if startCount >= target {
            return
        }
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        startWaiters.append((target, cont))
        for await _ in stream { break }
    }

    func waitUntilStopEntered() async {
        if stopCount > 0 {
            return
        }
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        stopEnteredWaiters.append(cont)
        for await _ in stream { break }
    }

    func emit(_ event: GazeEvent) {
        for cont in continuations.values {
            cont.yield(event)
        }
    }

    func finishAll() {
        let toClose = continuations
        continuations.removeAll()
        liveStreamIDs.removeAll()
        for cont in toClose.values {
            cont.finish()
        }
    }
}

actor SlowCatalog: WindowCatalogService {
    private let base: SimWindowCatalogService
    private let delayNanoseconds: UInt64
    private(set) var snapshotCalls: Int = 0
    private var snapshotWaiters: [(target: Int, cont: AsyncStream<Void>.Continuation)] = []

    init(wrapping base: SimWindowCatalogService, delayNanoseconds: UInt64) {
        self.base = base
        self.delayNanoseconds = delayNanoseconds
    }

    func snapshot() async -> WindowSnapshot {
        snapshotCalls += 1
        var remaining: [(target: Int, cont: AsyncStream<Void>.Continuation)] = []
        for waiter in snapshotWaiters {
            if snapshotCalls >= waiter.target {
                waiter.cont.finish()
            } else {
                remaining.append(waiter)
            }
        }
        snapshotWaiters = remaining

        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return await base.snapshot()
    }

    func waitForSnapshotCall(_ target: Int) async {
        if snapshotCalls >= target {
            return
        }
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        snapshotWaiters.append((target, cont))
        for await _ in stream { break }
    }
}

actor SteppingSleeper: Sleeper {
    private let clock: VirtualClock
    private let onSleep: (@Sendable (Int, TimeInterval) async -> Void)?
    private(set) var sleeps: [TimeInterval] = []

    init(clock: VirtualClock, onSleep: (@Sendable (Int, TimeInterval) async -> Void)? = nil) {
        self.clock = clock
        self.onSleep = onSleep
    }

    func sleep(seconds: TimeInterval) async {
        sleeps.append(seconds)
        let step = sleeps.count
        clock.advance(by: seconds)
        if let onSleep {
            await onSleep(step, seconds)
        }
        await Task.yield()
    }

    func sleepCount() -> Int {
        sleeps.count
    }
}

actor GatedBlockingSleeper: Sleeper {
    private(set) var sleepCount: Int = 0
    private(set) var sleeps: [TimeInterval] = []
    private var sleepEnteredWaiters: [(target: Int, cont: AsyncStream<Void>.Continuation)] = []

    func sleep(seconds: TimeInterval) async {
        sleepCount += 1
        sleeps.append(seconds)
        var remaining: [(target: Int, cont: AsyncStream<Void>.Continuation)] = []
        for w in sleepEnteredWaiters {
            if sleepCount >= w.target {
                w.cont.finish()
            } else {
                remaining.append(w)
            }
        }
        sleepEnteredWaiters = remaining

        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        await withTaskCancellationHandler {
            for await _ in stream { break }
        } onCancel: {
            cont.finish()
        }
    }

    func waitForSleepCall(_ target: Int) async {
        if sleepCount >= target {
            return
        }
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        sleepEnteredWaiters.append((target, cont))
        for await _ in stream { break }
    }
}

actor ClockAdvancingActuator: FocusActuator {
    private let base: SimFocusActuator
    private let clock: VirtualClock
    private let stepAdvance: TimeInterval
    private(set) var performCalls: [SimFocusActuator.PerformCall] = []

    init(base: SimFocusActuator, clock: VirtualClock, stepAdvance: TimeInterval = 0.6) {
        self.base = base
        self.clock = clock
        self.stepAdvance = stepAdvance
    }

    func windows(of pid: Int32) async -> [AXWindowCandidate] {
        await base.windows(of: pid)
    }

    func perform(_ step: FocusStep, pid: Int32, window: AXWindowCandidate) async -> FocusStepResult {
        performCalls.append(SimFocusActuator.PerformCall(step: step, pid: pid, candidate: window))
        clock.advance(by: stepAdvance)
        return await base.perform(step, pid: pid, window: window)
    }

    func keyWindowCheck(pid: Int32, expected: AXWindowCandidate) async -> KeyWindowCheck {
        await base.keyWindowCheck(pid: pid, expected: expected)
    }
}
