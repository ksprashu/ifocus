import CoreGraphics
import Foundation
import Testing
@testable import iFocusCore

@Suite("Scenario")
struct ScenarioTests {
    @Test("T35 deskThree 60s session across 10 seeds")
    func t35DeskThree60sAcross10Seeds() {
        let scenario = Scenario.deskThree60s()
        let config = Config()

        for seed in UInt64(1)...10 {
            let res = ScenarioRunner.run(scenario, seed: seed, config: config)
            guard case .success(let result) = res else {
                Issue.record("Seed \(seed) failed calibration: \(res)")
                return
            }
            #expect(result.actualSwitches == result.expectedSwitches)
            // Verify every intended switch happened within 1.0 s of segment start
            let switchSegments = scenario.segments.dropFirst()
            #expect(result.switchTimestamps.count == switchSegments.count)
            for (sw, seg) in zip(result.switchTimestamps, switchSegments) {
                let latency = sw.timestamp - seg.startTime
                #expect(latency >= 0 && latency <= 2.0)
            }
        }
    }

    @Test("T36 dualExternal switch precedes typing at 2000ms")
    func t36SwitchBeforeTyping() {
        let scenario = Scenario.dualExternalSwitchBeforeTyping()
        let res = ScenarioRunner.run(scenario, seed: 4, config: Config())
        guard case .success(let result) = res else {
            Issue.record("Scenario failed: \(res)")
            return
        }
        #expect(result.passed)
        #expect(result.switchTimestamps.count == 1)
        #expect((result.switchTimestamps.first?.timestamp ?? 99) < 2.00)
    }

    @Test("T37 dualExternal typing at 150ms defers switch across quiet period and fresh dwell")
    func t37MismatchDuringTypingThenSwitch() {
        let scenario = Scenario.dualExternalTypingThenQuiet()
        let res = ScenarioRunner.run(scenario, seed: 5, config: Config())
        guard case .success(let result) = res else {
            Issue.record("Scenario failed: \(res)")
            return
        }
        #expect(result.passed)
        #expect(result.switchTimestamps.count == 1)
        // Last key is at t = 1.35s, quiet window 2.5s + cross dwell 1.2s -> switch at/after 5.05s
        #expect((result.switchTimestamps.first?.timestamp ?? 0) >= 5.05 - 1e-6)
    }

    @Test("T44 dualExternal 250ms flyover produces zero intermediate switches")
    func t44FlyoverZeroIntermediateSwitches() {
        let scenario = Scenario.dualExternalFlyover()
        let res = ScenarioRunner.run(scenario, seed: 2, config: Config())
        guard case .success(let result) = res else {
            Issue.record("Scenario failed: \(res)")
            return
        }
        #expect(result.actualSwitches == [Rig.dualRightRightID])
    }

    @Test("T53 dualExternal scenario succeeds without window IDs")
    func t53PublicMatchingWithoutWindowIDs() async {
        let scenario = Scenario.dualExternalMultiMonitorTour()
        let config = Config()
        guard case .success(let prepared) = ScenarioRunner.prepare(scenario, seed: 3, config: config) else {
            Issue.record("Scenario prepare failed")
            return
        }

        let clock = VirtualClock(startAt: 0)
        let catalog = SimWindowCatalogService(
            windows: scenario.rig.windows,
            focusedWindowID: scenario.initialFocusedWindowID,
            clock: clock
        )
        let actuator = SimFocusActuator(catalog: catalog, exposeWindowIDs: false)
        let switcher = LadderFocusSwitcher(
            actuator: actuator,
            catalog: catalog,
            sleeper: VirtualSleeper(clock: clock)
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
            clock: clock
        )
        await coordinator.runUntilStreamFinishes()

        let log = await coordinator.log()
        let actualSwitches = log.compactMap { entry -> UInt32? in
            if case .focus(let w) = entry.action,
               case .switched = entry.outcome {
                return w.windowID
            }
            return nil
        }
        #expect(actualSwitches == scenario.expectedSwitches)
        #expect(await actuator.performCalls.allSatisfy { $0.candidate.windowID == nil })
    }

    @Test("T73 ScenarioRunner.runWithLadder matches sync runner and expected switches across scenarios and seeds")
    func t73RunWithLadderMatchesSyncAcrossScenariosAndSeeds() async {
        let scenarios: [Scenario] = [
            Scenario.deskThree60s(),
            Scenario.dualExternalSwitchBeforeTyping(),
            Scenario.dualExternalTypingThenQuiet(),
            Scenario.dualExternalMultiMonitorTour(),
            Scenario.dualExternalFlyover(),
        ]
        let config = Config()

        for scenario in scenarios {
            for seed in UInt64(1)...3 {
                let syncRes = ScenarioRunner.run(scenario, seed: seed, config: config)
                let ladderRes = await ScenarioRunner.runWithLadder(
                    scenario,
                    seed: seed,
                    config: config,
                    exposeWindowIDs: true
                )
                guard case .success(let expected) = syncRes,
                      case .success(let actual) = ladderRes else {
                    Issue.record("Scenario \(scenario.name) seed \(seed) failed")
                    return
                }
                #expect(actual.seed == seed)
                #expect(expected.seed == seed)
                #expect(actual.actualSwitches == scenario.expectedSwitches)
                #expect(actual.actualSwitches == expected.actualSwitches)
            }
        }

        // Public matching without window IDs on dualExternalMultiMonitorTour
        let t53Scenario = Scenario.dualExternalMultiMonitorTour()
        let publicRes = await ScenarioRunner.runWithLadder(
            t53Scenario,
            seed: 3,
            config: config,
            exposeWindowIDs: false
        )
        guard case .success(let publicResult) = publicRes else {
            Issue.record("Public runWithLadder failed")
            return
        }
        #expect(publicResult.seed == 3)
        #expect(publicResult.actualSwitches == t53Scenario.expectedSwitches)
    }

    @Test("T89 mixedAppsTour runWithLadder across 10 seeds verifies cross-PID rungB and same-PID rungA")
    func t89MixedAppsTourAcross10Seeds() async {
        let scenario = Scenario.mixedAppsTour()
        let config = Config()

        for seed in UInt64(1)...10 {
            let res = await ScenarioRunner.runWithLadder(scenario, seed: seed, config: config)
            guard case .success(let result) = res else {
                Issue.record("Seed \(seed) failed")
                return
            }
            #expect(result.passed)
            #expect(result.actualSwitches == [
                Rig.mixedSpotifyID,
                Rig.mixedChrome2ID,
                Rig.mixedChrome1ID,
                Rig.mixedGhosttyID,
            ])

            let switchEntries: [(id: UInt32, strategy: FocusStrategy, timestamp: TimeInterval)] = result.decisionLog.compactMap { entry in
                if case .focus(let w) = entry.action, case .switched(let strat) = entry.outcome {
                    return (w.windowID, strat, entry.timestamp)
                }
                return nil
            }
            #expect(switchEntries.count == 4)
            let expectedStrategies: [FocusStrategy] = [.rungB, .rungB, .rungA, .rungB]
            let expectedDwells: [TimeInterval] = [
                config.dwellCrossDisplaySeconds,
                config.dwellCrossDisplaySeconds,
                config.dwellSameDisplaySeconds,
                config.dwellCrossDisplaySeconds,
            ]
            let switchSegments = Array(scenario.segments.dropFirst())
            for i in 0..<min(switchEntries.count, switchSegments.count) {
                #expect(switchEntries[i].strategy == expectedStrategies[i])
                let latency = switchEntries[i].timestamp - switchSegments[i].startTime
                #expect(latency >= expectedDwells[i] - 1e-6 && latency <= expectedDwells[i] + 0.5)
            }
        }
    }

    @Test("T90 mixedAppsTypingWhileReading suppresses candidates across short pause and switches after quiet")
    func t90MixedAppsTypingWhileReadingAcross10Seeds() async {
        let scenario = Scenario.mixedAppsTypingWhileReading()
        let config = Config()
        let lastKeyAt: TimeInterval = 12.40

        for seed in UInt64(1)...10 {
            let res = await ScenarioRunner.runWithLadder(scenario, seed: seed, config: config)
            guard case .success(let result) = res else {
                Issue.record("Seed \(seed) failed")
                return
            }
            #expect(result.passed)

            let blockedEntries = result.decisionLog.filter { $0.timestamp < lastKeyAt + config.typingLockSeconds - 1e-6 }
            #expect(!blockedEntries.isEmpty)
            #expect(blockedEntries.allSatisfy { $0.candidateWindowID == nil })

            #expect(result.switchTimestamps.count == 1)
            if let sw = result.switchTimestamps.first {
                #expect(sw.windowID == Rig.mixedChrome1ID)
                #expect(sw.timestamp >= lastKeyAt + 3.7 - 1e-6 && sw.timestamp <= lastKeyAt + 4.2 + 1e-6)
            }
        }
    }

    @Test("T91 dualExternalTypeTooSoon produces zero switches pinning look-then-type tradeoff")
    func t91DualExternalTypeTooSoonZeroSwitches() async {
        let scenario = Scenario.dualExternalTypeTooSoon()
        let res = await ScenarioRunner.runWithLadder(scenario, seed: 1, config: Config())
        guard case .success(let result) = res else {
            Issue.record("Scenario failed")
            return
        }
        #expect(result.passed)
        #expect(result.actualSwitches.isEmpty)
    }
}
