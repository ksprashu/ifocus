import Foundation
import Testing
@testable import iFocusCore

@Suite("Coordinator", .timeLimit(.minutes(1)))
struct CoordinatorTests {
    @Test("T38 FocusCoordinator matches ScenarioRunner decision log")
    func t38CoordinatorMatchesScenarioRunner() async {
        let config = Config()
        let scenarios = [
            Scenario.dualExternalMultiMonitorTour(),
            Scenario.dualExternalTypingThenQuiet(),
        ]

        for scenario in scenarios {
            guard case .success(let prepared) = ScenarioRunner.prepare(scenario, seed: 1, config: config) else {
                Issue.record("Failed to prepare \(scenario.name)")
                return
            }

            let syncResult = ScenarioRunner.runPrepared(prepared, config: config, snapshotMaxAge: 0.2)

            let clock = VirtualClock(startAt: prepared.steps.first?.timestamp ?? 0)
            let catalog = SimWindowCatalogService(
                windows: scenario.rig.windows,
                focusedWindowID: scenario.initialFocusedWindowID,
                clock: clock
            )
            let actuator = SimFocusActuator(catalog: catalog, exposeWindowIDs: true)
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
                snapshotMaxAge: 0.2
            )

            // Wait for any initial paused state? No, default isPaused = false.
            await coordinator.runUntilStreamFinishes()
            let asyncLog = await coordinator.log()

            #expect(asyncLog == syncResult.decisionLog)
        }
    }

    private static func makeDualCalibratedProfile() -> CalibrationProfile? {
        var user = SyntheticUser(seed: 1)
        guard case .success(let profile) = user.calibrate(rig: Rig.dualExternal, noise: false) else {
            return nil
        }
        return profile
    }

    private static func makeFeatures(at t: TimeInterval, targetWindowID: UInt32 = Rig.dualRightRightID) -> GazeFeatures {
        let rig = Rig.dualExternal
        let win = rig.windows.first { $0.windowID == targetWindowID }!
        var user = SyntheticUser(seed: 1)
        return user.features(
            lookingAtGlobalPoint: CGPoint(x: win.bounds.midX, y: win.bounds.midY),
            rig: rig,
            timestamp: t,
            noise: false
        )
    }

    @Test("T55 SlowCatalog start then stop leaves estimator idle")
    func t55SlowCatalogStartStopNoLeak() async {
        guard let profile = Self.makeDualCalibratedProfile() else {
            Issue.record("Calibration failed")
            return
        }

        // Case A: stop arrives while SlowCatalog.snapshot() is actively sleeping (50 ms)
        let clockA = VirtualClock(startAt: 0)
        let baseCatA = SimWindowCatalogService(
            windows: Rig.dualExternal.windows,
            focusedWindowID: Rig.dualLeftTopID,
            clock: clockA
        )
        let slowCatA = SlowCatalog(wrapping: baseCatA, delayNanoseconds: 50_000_000)
        let estA = RecordingEstimator()
        let coordA = FocusCoordinator(
            config: Config(),
            profile: profile,
            gazeEstimator: estA,
            topologyService: SimDisplayTopologyService(topology: Rig.dualExternal.topology),
            windowCatalog: slowCatA,
            inputProvider: ManualInputActivityProvider(),
            sessionProvider: ManualSessionStateProvider(active: true),
            focusSwitcher: SimFocusSwitcher(),
            clock: clockA
        )
        await coordA.start()
        await slowCatA.waitForSnapshotCall(1)
        await coordA.stop()
        #expect(await estA.isLive == false)
        #expect(await estA.startCount <= 1)

        // Case B: immediate start then stop with 50 ms SlowCatalog
        let clockB = VirtualClock(startAt: 0)
        let baseCatB = SimWindowCatalogService(
            windows: Rig.dualExternal.windows,
            focusedWindowID: Rig.dualLeftTopID,
            clock: clockB
        )
        let slowCatB = SlowCatalog(wrapping: baseCatB, delayNanoseconds: 50_000_000)
        let estB = RecordingEstimator()
        let coordB = FocusCoordinator(
            config: Config(),
            profile: profile,
            gazeEstimator: estB,
            topologyService: SimDisplayTopologyService(topology: Rig.dualExternal.topology),
            windowCatalog: slowCatB,
            inputProvider: ManualInputActivityProvider(),
            sessionProvider: ManualSessionStateProvider(active: true),
            focusSwitcher: SimFocusSwitcher(),
            clock: clockB
        )
        await coordB.start()
        await coordB.stop()
        #expect(await estB.isLive == false)
        #expect(await estB.startCount <= 1)
    }

    @Test("T56 start during slow stop returns within 2s and keeps at most one live stream")
    func t56StartDuringInFlightStop() async {
        guard let profile = Self.makeDualCalibratedProfile() else {
            Issue.record("Calibration failed")
            return
        }
        let clock = VirtualClock(startAt: 0)
        let catalog = SimWindowCatalogService(
            windows: Rig.dualExternal.windows,
            focusedWindowID: Rig.dualLeftTopID,
            clock: clock
        )
        let estimator = RecordingEstimator(stopDelayNanoseconds: 50_000_000)
        let coordinator = FocusCoordinator(
            config: Config(),
            profile: profile,
            gazeEstimator: estimator,
            topologyService: SimDisplayTopologyService(topology: Rig.dualExternal.topology),
            windowCatalog: catalog,
            inputProvider: ManualInputActivityProvider(),
            sessionProvider: ManualSessionStateProvider(active: true),
            focusSwitcher: SimFocusSwitcher(),
            clock: clock
        )

        await coordinator.start()
        await estimator.waitForStartCount(1)

        let stopTask = Task {
            await coordinator.stop()
        }
        await estimator.waitUntilStopEntered()

        // Re-start while the 50 ms stop is in flight.
        await coordinator.start()

        let stopReturnedPromptly = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await stopTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(stopReturnedPromptly)

        await estimator.waitForStartCount(2)
        #expect(await estimator.maxLiveStreams <= 1)

        await coordinator.stop()
        #expect(await estimator.isLive == false)
        #expect(await estimator.liveStreams == 0)
    }

    @Test("T57 WatchedStream silence stall reset cancel and source finish")
    func t57WatchedStreamBehavior() async {
        // 1. Silent source yields .stalled once at 5 s virtual time and finishes
        do {
            let clock = VirtualClock(startAt: 0)
            let sleeper = SteppingSleeper(clock: clock)
            let (source, _) = AsyncStream.makeStream(of: Int.self)
            let watched = WatchedStream(
                source: source,
                timeout: 5.0,
                clock: clock,
                sleeper: sleeper,
                pollInterval: 0.5
            )
            var stalledCount = 0
            var eventCount = 0
            for await item in watched.stream {
                switch item {
                case .event: eventCount += 1
                case .stalled: stalledCount += 1
                }
            }
            #expect(eventCount == 0)
            #expect(stalledCount == 1)
            #expect(clock.now() == 5.0)
        }

        // 2. Three events then silence stalls 5 s after the last event
        do {
            let clock = VirtualClock(startAt: 0)
            let gateEntered = AsyncSignalGate()
            let gateRelease = AsyncSignalGate()
            let sleeper = SteppingSleeper(clock: clock) { step, _ in
                if step == 1 {
                    await gateEntered.open()
                    await gateRelease.wait()
                }
            }
            let (source, sourceCont) = AsyncStream.makeStream(of: Int.self)
            let watched = WatchedStream(
                source: source,
                timeout: 5.0,
                clock: clock,
                sleeper: sleeper,
                pollInterval: 0.5
            )
            await gateEntered.wait()

            var iter = watched.stream.makeAsyncIterator()
            for idx in 1...3 {
                clock.set(Double(idx))
                sourceCont.yield(idx)
                let received = await iter.next()
                if case .event(let val) = received {
                    #expect(val == idx)
                } else {
                    Issue.record("Expected event \(idx), got \(String(describing: received))")
                }
            }

            await gateRelease.open()
            let next = await iter.next()
            if case .stalled = next {
                // expected
            } else {
                Issue.record("Expected .stalled after 5 s silence")
            }
            #expect(await iter.next() == nil)
            #expect(clock.now() == 8.0)
        }

        // 3. cancel() finishes with zero .stalled events
        do {
            let clock = VirtualClock(startAt: 0)
            let sleeper = GatedBlockingSleeper()
            let (source, _) = AsyncStream.makeStream(of: Int.self)
            let watched = WatchedStream(
                source: source,
                timeout: 5.0,
                clock: clock,
                sleeper: sleeper,
                pollInterval: 0.5
            )
            await sleeper.waitForSleepCall(1)
            watched.cancel()
            var items: [Watched<Int>] = []
            for await item in watched.stream {
                items.append(item)
            }
            #expect(items.isEmpty)
        }

        // 4. Finished source finishes the watched stream without stalling
        do {
            let clock = VirtualClock(startAt: 0)
            let sleeper = GatedBlockingSleeper()
            let (source, sourceCont) = AsyncStream.makeStream(of: Int.self)
            sourceCont.yield(42)
            sourceCont.finish()
            let watched = WatchedStream(
                source: source,
                timeout: 5.0,
                clock: clock,
                sleeper: sleeper,
                pollInterval: 0.5
            )
            var values: [Int] = []
            var sawStall = false
            for await item in watched.stream {
                switch item {
                case .event(let v): values.append(v)
                case .stalled: sawStall = true
                }
            }
            #expect(values == [42])
            #expect(!sawStall)
        }
    }

    @Test("T64 decision log ring buffer bounds at 4096 newest entries in order")
    func t64BoundedDecisionLog() async {
        actor UnfoldingEstimator: GazeEstimator {
            let clock: VirtualClock
            let count: Int
            var idx = 0
            init(clock: VirtualClock, count: Int) {
                self.clock = clock
                self.count = count
            }
            func nextEvent() -> GazeEvent? {
                guard idx < count else { return nil }
                let t = Double(idx) * 0.05
                clock.set(t)
                idx += 1
                return .noFace(t)
            }
            func start() async throws -> AsyncStream<GazeEvent> {
                AsyncStream { await self.nextEvent() }
            }
            func stop() async {}
        }

        let clock = VirtualClock(startAt: 0)
        let catalog = SimWindowCatalogService(
            windows: Rig.dualExternal.windows,
            focusedWindowID: Rig.dualLeftTopID,
            clock: clock
        )
        let coordinator = FocusCoordinator(
            config: Config(),
            profile: Self.makeDualCalibratedProfile(),
            gazeEstimator: UnfoldingEstimator(clock: clock, count: 5000),
            topologyService: SimDisplayTopologyService(topology: Rig.dualExternal.topology),
            windowCatalog: catalog,
            inputProvider: ManualInputActivityProvider(),
            sessionProvider: ManualSessionStateProvider(active: true),
            focusSwitcher: SimFocusSwitcher(),
            clock: clock
        )

        await coordinator.runUntilStreamFinishes()
        let log = await coordinator.log()
        #expect(log.count == 4096)
        #expect(await coordinator.diagnostics().logCount == 4096)
        #expect(abs((log.first?.timestamp ?? -1) - Double(5000 - 4096) * 0.05) < 1e-9)
        #expect(abs((log.last?.timestamp ?? -1) - Double(4999) * 0.05) < 1e-9)
        for i in 1..<log.count {
            #expect(log[i].timestamp > log[i - 1].timestamp)
        }
    }

    @Test("T69 status deduplication and 1s permission cache invalidated by setPaused")
    func t69StatusDeduplicationAndPermissionCache() async {
        actor NoFaceBurstEstimator: GazeEstimator {
            let clock: VirtualClock
            let count: Int
            var idx = 0
            init(clock: VirtualClock, count: Int) {
                self.clock = clock
                self.count = count
            }
            func nextEvent() -> GazeEvent? {
                guard idx < count else { return nil }
                let t = Double(idx) * 0.05
                clock.set(t)
                idx += 1
                return .noFace(t)
            }
            func start() async throws -> AsyncStream<GazeEvent> {
                AsyncStream { await self.nextEvent() }
            }
            func stop() async {}
        }

        let clock = VirtualClock(startAt: 0)
        let catalog = SimWindowCatalogService(
            windows: Rig.dualExternal.windows,
            focusedWindowID: Rig.dualLeftTopID,
            clock: clock
        )
        let coordinator = FocusCoordinator(
            config: Config(),
            profile: Self.makeDualCalibratedProfile(),
            gazeEstimator: NoFaceBurstEstimator(clock: clock, count: 200),
            topologyService: SimDisplayTopologyService(topology: Rig.dualExternal.topology),
            windowCatalog: catalog,
            inputProvider: ManualInputActivityProvider(),
            sessionProvider: ManualSessionStateProvider(active: true),
            focusSwitcher: SimFocusSwitcher(),
            clock: clock
        )

        await coordinator.runUntilStreamFinishes()
        let diagBefore = await coordinator.diagnostics()
        #expect(diagBefore.permissionChecks <= 12)
        #expect(diagBefore.statusPublishes >= 1 && diagBefore.statusPublishes <= 3)

        // clock.now() is still 9.95 (< 1.0 s since check at 9.0), yet setPaused clears cache
        await coordinator.setPaused(true)
        let diagAfter = await coordinator.diagnostics()
        #expect(diagAfter.permissionChecks == diagBefore.permissionChecks + 1)
    }

    @Test("T70 stream interruption triggers error status reconnect and prompt stop during backoff")
    func t70StreamInterruptionReconnectAndBackoffCancel() async {
        guard let profile = Self.makeDualCalibratedProfile() else {
            Issue.record("Calibration failed")
            return
        }

        // 1. Interruption on stream 1 publishes .error with detail, retries via sleeper, processes stream 2
        do {
            let clock = VirtualClock(startAt: 0)
            let catalog = SimWindowCatalogService(
                windows: Rig.dualExternal.windows,
                focusedWindowID: Rig.dualLeftTopID,
                clock: clock
            )
            let sleeper = SteppingSleeper(clock: clock)
            let estimator = RecordingEstimator(handlers: [
                { _, cont in
                    cont.yield(.interrupted("disconnected"))
                    cont.finish()
                }
            ])
            let switcher = SimFocusSwitcher()
            let coordinator = FocusCoordinator(
                config: Config.v1Mechanics,
                profile: profile,
                gazeEstimator: estimator,
                topologyService: SimDisplayTopologyService(topology: Rig.dualExternal.topology),
                windowCatalog: catalog,
                inputProvider: ManualInputActivityProvider(),
                sessionProvider: ManualSessionStateProvider(active: true),
                focusSwitcher: switcher,
                clock: clock,
                retrySleeper: sleeper
            )

            let eventStream = await coordinator.events()
            await coordinator.start()

            var sawErrorDetail = false
            for await event in eventStream {
                if case .status(let status) = event, status.state == .error {
                    #expect(status.detail == "disconnected")
                    sawErrorDetail = true
                    break
                }
            }
            #expect(sawErrorDetail)

            await estimator.waitForStartCount(2)
            #expect(await coordinator.diagnostics().estimatorStarts == 2)

            clock.set(5.0)
            await estimator.emit(.features(Self.makeFeatures(at: 5.0)))
            while await coordinator.diagnostics().logCount < 2 {
                await Task.yield()
            }
            clock.set(5.35)
            await estimator.emit(.features(Self.makeFeatures(at: 5.35)))

            var switchedToTarget = false
            for await event in eventStream {
                if case .switched(let win, _) = event {
                    switchedToTarget = (win.windowID == Rig.dualRightRightID)
                    break
                }
            }
            #expect(switchedToTarget)
            await coordinator.stop()
        }

        // 2. stop() during backoff returns promptly and prevents the second estimator start
        do {
            let clock = VirtualClock(startAt: 0)
            let catalog = SimWindowCatalogService(
                windows: Rig.dualExternal.windows,
                focusedWindowID: Rig.dualLeftTopID,
                clock: clock
            )
            let sleeper = GatedBlockingSleeper()
            let estimator = RecordingEstimator(handlers: [
                { _, cont in
                    cont.yield(.interrupted("disconnected"))
                    cont.finish()
                }
            ])
            let coordinator = FocusCoordinator(
                config: Config.v1Mechanics,
                profile: profile,
                gazeEstimator: estimator,
                topologyService: SimDisplayTopologyService(topology: Rig.dualExternal.topology),
                windowCatalog: catalog,
                inputProvider: ManualInputActivityProvider(),
                sessionProvider: ManualSessionStateProvider(active: true),
                focusSwitcher: SimFocusSwitcher(),
                clock: clock,
                retrySleeper: sleeper
            )

            await coordinator.start()
            await sleeper.waitForSleepCall(1)
            await coordinator.stop()
            #expect(await estimator.startCount == 1)
            #expect(await coordinator.diagnostics().estimatorStarts == 1)
        }
    }

    @Test("T77 security prompt sets status detail and removal clears it")
    func t77SecurityPromptStatusDetailAndClear() async {
        guard let profile = Self.makeDualCalibratedProfile() else {
            Issue.record("Calibration failed")
            return
        }
        let clock = VirtualClock(startAt: 0)
        let promptWin = WindowDescriptor(
            windowID: 999,
            pid: 9999,
            bundleID: "com.apple.SecurityAgent",
            bounds: CGRect(x: 400, y: 300, width: 420, height: 220),
            zIndex: 0,
            layer: 8
        )
        let catalog = SimWindowCatalogService(
            windows: [promptWin] + Rig.dualExternal.windows,
            focusedWindowID: Rig.dualLeftTopID,
            clock: clock
        )
        let estimator = RecordingEstimator()
        let coordinator = FocusCoordinator(
            config: Config(),
            profile: profile,
            gazeEstimator: estimator,
            topologyService: SimDisplayTopologyService(topology: Rig.dualExternal.topology),
            windowCatalog: catalog,
            inputProvider: ManualInputActivityProvider(),
            sessionProvider: ManualSessionStateProvider(active: true),
            focusSwitcher: SimFocusSwitcher(),
            clock: clock,
            snapshotMaxAge: 0.0
        )

        let eventStream = await coordinator.events()
        await coordinator.start()
        await estimator.waitForStartCount(1)

        clock.set(1.0)
        await estimator.emit(.features(Self.makeFeatures(at: 1.0)))

        var observedPromptDetail: String?
        for await event in eventStream {
            if case .status(let status) = event, status.lastVeto == .sourceNotAllowed {
                observedPromptDetail = status.detail
                break
            }
        }
        #expect(observedPromptDetail == "System prompt on screen: com.apple.SecurityAgent")

        await catalog.removeWindow(id: 999)
        clock.set(2.0)
        await estimator.emit(.features(Self.makeFeatures(at: 2.0)))

        var clearedDetail = false
        for await event in eventStream {
            if case .status(let status) = event, status.detail == nil && status.lastVeto == nil {
                clearedDetail = true
                break
            }
        }
        #expect(clearedDetail)
        await coordinator.stop()
    }

    @Test("T78 inactive session gates estimator start with retry backoff and exits without sleeper")
    func t78SessionInactiveGateBeforeStart() async {
        guard let profile = Self.makeDualCalibratedProfile() else {
            Issue.record("Calibration failed")
            return
        }

        // 1. With retry sleeper: 0 starts across 3 sleeps, then 1 start once session becomes active
        do {
            let clock = VirtualClock(startAt: 0)
            let catalog = SimWindowCatalogService(
                windows: Rig.dualExternal.windows,
                focusedWindowID: Rig.dualLeftTopID,
                clock: clock
            )
            let sessionProvider = ManualSessionStateProvider(active: false)
            let estimator = RecordingEstimator()
            let sleeper = SteppingSleeper(clock: clock) { step, _ in
                #expect(await estimator.startCount == 0)
                if step == 3 {
                    sessionProvider.setActive(true)
                }
            }
            let coordinator = FocusCoordinator(
                config: Config(),
                profile: profile,
                gazeEstimator: estimator,
                topologyService: SimDisplayTopologyService(topology: Rig.dualExternal.topology),
                windowCatalog: catalog,
                inputProvider: ManualInputActivityProvider(),
                sessionProvider: sessionProvider,
                focusSwitcher: SimFocusSwitcher(),
                clock: clock,
                retrySleeper: sleeper
            )

            await coordinator.start()
            await estimator.waitForStartCount(1)
            #expect(await sleeper.sleepCount() == 3)
            #expect(await estimator.startCount == 1)
            await coordinator.stop()
        }

        // 2. Without retry sleeper: exits immediately with 0 estimator starts
        do {
            let clock = VirtualClock(startAt: 0)
            let catalog = SimWindowCatalogService(
                windows: Rig.dualExternal.windows,
                focusedWindowID: Rig.dualLeftTopID,
                clock: clock
            )
            let estimator = RecordingEstimator()
            let coordinator = FocusCoordinator(
                config: Config(),
                profile: profile,
                gazeEstimator: estimator,
                topologyService: SimDisplayTopologyService(topology: Rig.dualExternal.topology),
                windowCatalog: catalog,
                inputProvider: ManualInputActivityProvider(),
                sessionProvider: ManualSessionStateProvider(active: false),
                focusSwitcher: SimFocusSwitcher(),
                clock: clock,
                retrySleeper: nil
            )

            let eventStream = await coordinator.events()
            await coordinator.start()
            for await event in eventStream {
                if case .status(let status) = event, status.lastVeto == .sessionInactive {
                    break
                }
            }
            await coordinator.stop()
            #expect(await estimator.startCount == 0)
            #expect(await coordinator.diagnostics().estimatorStarts == 0)
        }
    }
}
