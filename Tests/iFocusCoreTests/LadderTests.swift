import CoreGraphics
import Testing
@testable import iFocusCore

@Suite("Ladder")
struct LadderTests {
    @Test("T31 ladder rung escalation A B C and unverified")
    func t31LadderEscalation() async {
        let windows = Rig.dualExternal.windows
        let targetSamePID = windows.first { $0.windowID == Rig.dualRightRightID }!
        let targetOtherPID = windows.first { $0.windowID == Rig.dualLeftRightApp2ID }!

        // 1. Same-app stops at rung A
        let clock1 = VirtualClock()
        let cat1 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock1)
        let act1 = SimFocusActuator(catalog: cat1)
        let lad1 = LadderFocusSwitcher(actuator: act1, catalog: cat1, sleeper: VirtualSleeper(clock: clock1))
        #expect(await lad1.focus(targetSamePID) == .switched(.rungA))
        #expect(await act1.performCalls.count == 1)

        // 2. Background app stops at rung B when setAppFrontmost works
        let clock2 = VirtualClock()
        let cat2 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock2)
        let act2 = SimFocusActuator(catalog: cat2, allowAXFrontmost: true, allowActivateApp: true)
        let lad2 = LadderFocusSwitcher(actuator: act2, catalog: cat2, sleeper: VirtualSleeper(clock: clock2))
        #expect(await lad2.focus(targetOtherPID) == .switched(.rungB))

        // 3. Background app escalates to rung C when setAppFrontmost does not bring app frontmost
        let clock3 = VirtualClock()
        let cat3 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock3)
        let act3 = SimFocusActuator(catalog: cat3, allowAXFrontmost: false, allowActivateApp: true)
        let lad3 = LadderFocusSwitcher(actuator: act3, catalog: cat3, sleeper: VirtualSleeper(clock: clock3))
        #expect(await lad3.focus(targetOtherPID) == .switched(.rungC))

        // 4. All rungs fail verification -> .failed(.unverified)
        let clock4 = VirtualClock()
        let cat4 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock4)
        let act4 = SimFocusActuator(catalog: cat4, failAllSwitches: true)
        let lad4 = LadderFocusSwitcher(actuator: act4, catalog: cat4, sleeper: VirtualSleeper(clock: clock4))
        #expect(await lad4.focus(targetOtherPID) == .failed(.unverified))
    }

    @Test("T32 ladder verification catches wrong raised window")
    func t32VerificationCatchesWrongWindow() async {
        let clock = VirtualClock()
        let cat = SimWindowCatalogService(windows: Rig.dualExternal.windows, focusedWindowID: Rig.dualLeftTopID, clock: clock)
        let act = SimFocusActuator(catalog: cat, wrongWindowIDToRaise: Rig.dualLeftBottomID)
        let lad = LadderFocusSwitcher(actuator: act, catalog: cat, sleeper: VirtualSleeper(clock: clock))

        let target = Rig.dualExternal.windows.first { $0.windowID == Rig.dualRightRightID }!
        let outcome = await lad.focus(target)
        #expect(outcome == .failed(.unverified))
    }

    @Test("T45 ladder re-enumerates after AX reorder and refuses stale candidate")
    func t45ReenumerationAndStaleRejection() async {
        let windows = Rig.dualExternal.windows
        let targetOtherPID = windows.first { $0.windowID == Rig.dualLeftRightApp2ID }!

        // Reorders AX list after rung A -> rung B still matches target after re-enumeration
        let clock1 = VirtualClock()
        let cat1 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock1)
        let act1 = SimFocusActuator(catalog: cat1, allowAXFrontmost: true, reorderAXOrderAfterRungA: true)
        let lad1 = LadderFocusSwitcher(actuator: act1, catalog: cat1, sleeper: VirtualSleeper(clock: clock1))
        #expect(await lad1.focus(targetOtherPID) == .switched(.rungB))
        #expect(await act1.windowsCallCount >= 2)

        // Stale candidate refusal: actuator returns false and never changes focusedWindowID
        let clock2 = VirtualClock()
        let cat2 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock2)
        let act2 = SimFocusActuator(catalog: cat2, rejectIdentityMismatch: true)
        let lad2 = LadderFocusSwitcher(actuator: act2, catalog: cat2, sleeper: VirtualSleeper(clock: clock2))
        let outcome = await lad2.focus(Rig.dualExternal.windows.first { $0.windowID == Rig.dualRightRightID }!)
        #expect(outcome == .failed(.staleCandidate))
        #expect(await cat2.snapshot().focusedWindowID == Rig.dualLeftTopID)
    }

    @Test("T46 already focused target short-circuits with zero actuator calls")
    func t46AlreadyFocusedShortCircuit() async {
        let clock = VirtualClock()
        let cat = SimWindowCatalogService(windows: Rig.dualExternal.windows, focusedWindowID: Rig.dualLeftTopID, clock: clock)
        let act = SimFocusActuator(catalog: cat)
        let lad = LadderFocusSwitcher(actuator: act, catalog: cat, sleeper: VirtualSleeper(clock: clock))

        let already = Rig.dualExternal.windows.first { $0.windowID == Rig.dualLeftTopID }!
        let outcome = await lad.focus(already)
        #expect(outcome == .alreadyFocused)
        #expect(await act.windowsCallCount == 0)
        #expect(await act.performCalls.isEmpty)
    }

    @Test("T58 ladder deadline returns timedOut without attempting rung C and clock nil runs all rungs")
    func t58DeadlineTimedOutVsNoClock() async {
        let windows = Rig.dualExternal.windows
        let targetOtherPID = windows.first { $0.windowID == Rig.dualLeftRightApp2ID }!

        // 1. With clock and 0.6 s/step: deadline (1.0 s) expires before rung C
        let clock1 = VirtualClock(startAt: 0)
        let cat1 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock1)
        let base1 = SimFocusActuator(catalog: cat1, failAllSwitches: true)
        let adv1 = ClockAdvancingActuator(base: base1, clock: clock1, stepAdvance: 0.6)
        let lad1 = LadderFocusSwitcher(
            actuator: adv1,
            catalog: cat1,
            sleeper: VirtualSleeper(clock: clock1),
            clock: clock1,
            deadlineSeconds: 1.0
        )
        let outcome1 = await lad1.focus(targetOtherPID)
        #expect(outcome1 == .failed(.timedOut))
        let calls1 = await adv1.performCalls
        #expect(!calls1.contains { $0.step == .activateApp })

        // 2. Without clock (clock == nil): same slow actuator runs all three rungs including rung C
        let clock2 = VirtualClock(startAt: 0)
        let cat2 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock2)
        let base2 = SimFocusActuator(catalog: cat2, failAllSwitches: true)
        let adv2 = ClockAdvancingActuator(base: base2, clock: clock2, stepAdvance: 0.6)
        let lad2 = LadderFocusSwitcher(
            actuator: adv2,
            catalog: cat2,
            sleeper: VirtualSleeper(clock: clock2),
            clock: nil
        )
        let outcome2 = await lad2.focus(targetOtherPID)
        #expect(outcome2 == .failed(.unverified))
        let calls2 = await adv2.performCalls
        #expect(calls2.contains { $0.step == .activateApp })
        #expect(calls2.count == 6)
    }

    @Test("T66 unverified ladder rolls back focus and timedOut same-PID skips rollback")
    func t66RollbackOnUnverifiedAndSamePIDTimeoutSkip() async {
        let windows = Rig.dualExternal.windows
        let targetOtherPID = windows.first { $0.windowID == Rig.dualLeftRightApp2ID }!
        let targetSamePID = windows.first { $0.windowID == Rig.dualRightRightID }!

        // 1. Wrong raised window for target only -> unverified rolls back to initial window
        let clock1 = VirtualClock(startAt: 0)
        let cat1 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock1)
        let act1 = SimFocusActuator(
            catalog: cat1,
            wrongWindowIDToRaise: Rig.dualLeftBottomID,
            wrongWindowOnlyForTargetID: targetOtherPID.windowID
        )
        let lad1 = LadderFocusSwitcher(actuator: act1, catalog: cat1, sleeper: VirtualSleeper(clock: clock1))
        let outcome1 = await lad1.focus(targetOtherPID)
        #expect(outcome1 == .failed(.unverified))
        #expect(await cat1.snapshot().focusedWindowID == Rig.dualLeftTopID)

        // 2. Timed-out ladder sharing PID between initial window and target makes zero rollback calls
        let clock2 = VirtualClock(startAt: 0)
        let cat2 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock2)
        let base2 = SimFocusActuator(
            catalog: cat2,
            wrongWindowIDToRaise: Rig.dualLeftBottomID,
            wrongWindowOnlyForTargetID: targetSamePID.windowID
        )
        let adv2 = ClockAdvancingActuator(base: base2, clock: clock2, stepAdvance: 0.6)
        let lad2 = LadderFocusSwitcher(
            actuator: adv2,
            catalog: cat2,
            sleeper: VirtualSleeper(clock: clock2),
            clock: clock2,
            deadlineSeconds: 1.0
        )
        let outcome2 = await lad2.focus(targetSamePID)
        #expect(outcome2 == .failed(.timedOut))
        let calls2 = await adv2.performCalls
        #expect(calls2.allSatisfy { $0.candidate.windowID == targetSamePID.windowID })
        #expect(await cat2.snapshot().focusedWindowID == Rig.dualLeftBottomID)
    }

    @Test("T68 resolveFocusedWindowID threshold and keyWindowCheck gate")
    func t68ResolveFocusedWindowIDAndKeyWindowGate() async {
        // 1. Skips small 100x60 overlay in front of 800x600 layer-0 window
        let small = WindowDescriptor(windowID: 1, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: 0, y: 0, width: 100, height: 60), zIndex: 0, layer: 0)
        let large = WindowDescriptor(windowID: 2, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: 0, y: 0, width: 800, height: 600), zIndex: 1, layer: 0)
        #expect(WindowSnapshot.resolveFocusedWindowID(windows: [small, large], frontmostPID: 1001) == 2)

        // Falls back to small window when no >= 120x80 layer-0 window exists
        let tiny2 = WindowDescriptor(windowID: 3, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: 10, y: 10, width: 90, height: 50), zIndex: 1, layer: 0)
        #expect(WindowSnapshot.resolveFocusedWindowID(windows: [small, tiny2], frontmostPID: 1001) == 1)

        // 2. keyWindowOverride == .differs blocks .switched; .unknown allows .switched
        let target = Rig.dualExternal.windows.first { $0.windowID == Rig.dualRightRightID }!

        let clock1 = VirtualClock()
        let cat1 = SimWindowCatalogService(windows: Rig.dualExternal.windows, focusedWindowID: Rig.dualLeftTopID, clock: clock1)
        let actDiffers = SimFocusActuator(catalog: cat1, keyWindowOverride: .differs)
        let ladDiffers = LadderFocusSwitcher(actuator: actDiffers, catalog: cat1, sleeper: VirtualSleeper(clock: clock1))
        let outDiffers = await ladDiffers.focus(target)
        #expect(outDiffers == .failed(.unverified))

        let clock2 = VirtualClock()
        let cat2 = SimWindowCatalogService(windows: Rig.dualExternal.windows, focusedWindowID: Rig.dualLeftTopID, clock: clock2)
        let actUnknown = SimFocusActuator(catalog: cat2, keyWindowOverride: .unknown)
        let ladUnknown = LadderFocusSwitcher(actuator: actUnknown, catalog: cat2, sleeper: VirtualSleeper(clock: clock2))
        let outUnknown = await ladUnknown.focus(target)
        #expect(outUnknown == .switched(.rungA))
    }

    @Test("T72 rung C steps notTrusted immediate return and refused yields unverified")
    func t72RungCStepsAndStepResultDiscrimination() async {
        let windows = Rig.dualExternal.windows
        let targetOtherPID = windows.first { $0.windowID == Rig.dualLeftRightApp2ID }!

        // 1. Rung C performs raiseAndMakeMain then activateApp (exact 2 steps)
        let clock1 = VirtualClock()
        let cat1 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock1)
        let act1 = SimFocusActuator(catalog: cat1, allowAXFrontmost: false, allowActivateApp: true)
        let lad1 = LadderFocusSwitcher(actuator: act1, catalog: cat1, sleeper: VirtualSleeper(clock: clock1))
        #expect(await lad1.focus(targetOtherPID) == .switched(.rungC))
        let calls1 = await act1.performCalls
        #expect(calls1.count == 6)
        #expect(Array(calls1.suffix(3).map(\.step)) == [.raiseAndMakeMain, .activateApp, .raiseAndMakeMain])

        // 2. .notTrusted returns .failed(.notTrusted) after single call
        let clock2 = VirtualClock()
        let cat2 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock2)
        let act2 = SimFocusActuator(catalog: cat2, forcedStepResult: .notTrusted)
        let lad2 = LadderFocusSwitcher(actuator: act2, catalog: cat2, sleeper: VirtualSleeper(clock: clock2))
        #expect(await lad2.focus(targetOtherPID) == .failed(.notTrusted))
        #expect(await act2.performCalls.count == 1)

        // 3. .refused on every step yields .failed(.unverified), never .staleCandidate
        let clock3 = VirtualClock()
        let cat3 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.dualLeftTopID, clock: clock3)
        let act3 = SimFocusActuator(catalog: cat3, forcedStepResult: .refused)
        let lad3 = LadderFocusSwitcher(actuator: act3, catalog: cat3, sleeper: VirtualSleeper(clock: clock3))
        #expect(await lad3.focus(targetOtherPID) == .failed(.unverified))
    }

    @Test("T86 Ghostty to Spotify uses rungB 3 steps skips rungA and matches key window")
    func t86GhosttyToSpotifyCrossPID() async {
        let windows = Rig.mixedApps.windows
        let spotify = windows.first { $0.windowID == Rig.mixedSpotifyID }!
        let clock = VirtualClock(startAt: 0)
        let cat = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.mixedGhosttyID, clock: clock)
        let act = SimFocusActuator(catalog: cat)
        let lad = LadderFocusSwitcher(actuator: act, catalog: cat, sleeper: VirtualSleeper(clock: clock), clock: clock)

        let outcome = await lad.focus(spotify)
        #expect(outcome == .switched(.rungB))
        let calls = await act.performCalls
        #expect(calls.map(\.step) == [.raiseAndMakeMain, .setAppFrontmost, .raiseAndMakeMain])
        let snap = await cat.snapshot()
        #expect(snap.frontmostPID == spotify.pid)
        #expect(snap.focusedWindowID == spotify.windowID)
        let candidate = AXWindowCandidate(index: 0, windowID: spotify.windowID, frame: spotify.bounds)
        #expect(await act.keyWindowCheck(pid: spotify.pid, expected: candidate) == .matches)
    }

    @Test("T87 Ghostty to Chrome window 2 with background raise ignored then Chrome 2 to Chrome 1 via rungA")
    func t87ChromeMultiWindowAndSamePIDFollowUp() async {
        for exposeIDs in [true, false] {
            let windows = Rig.mixedApps.windows
            let chrome1 = windows.first { $0.windowID == Rig.mixedChrome1ID }!
            let chrome2 = windows.first { $0.windowID == Rig.mixedChrome2ID }!
            let clock = VirtualClock(startAt: 0)
            let cat = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.mixedGhosttyID, clock: clock)
            let act = SimFocusActuator(catalog: cat, exposeWindowIDs: exposeIDs, ignoreRaiseWhileAppInBackground: true)
            let lad = LadderFocusSwitcher(actuator: act, catalog: cat, sleeper: VirtualSleeper(clock: clock), clock: clock)

            let outCross = await lad.focus(chrome2)
            #expect(outCross == .switched(.rungB))
            let snapAfterCross = await cat.snapshot()
            #expect(snapAfterCross.frontmostPID == chrome2.pid)
            #expect(snapAfterCross.focusedWindowID == Rig.mixedChrome2ID)

            let callsBeforeSamePID = await act.performCalls.count
            let outSame = await lad.focus(chrome1)
            #expect(outSame == .switched(.rungA))
            let allCalls = await act.performCalls
            let sameCalls = Array(allCalls.dropFirst(callsBeforeSamePID))
            #expect(sameCalls.map(\.step) == [.raiseAndMakeMain])
            #expect(await cat.snapshot().focusedWindowID == Rig.mixedChrome1ID)
        }
    }

    @Test("T88 raise without app activation returns unverified and stale after wrong raise rolls back")
    func t88CrossPIDVerificationRequiresFrontmostAndStaleRollsBack() async {
        // 1. Raises without bringing target app frontmost -> never .switched, .failed(.unverified), restored to Ghostty
        do {
            let windows = Rig.mixedApps.windows
            let spotify = windows.first { $0.windowID == Rig.mixedSpotifyID }!
            let clock = VirtualClock(startAt: 0)
            let cat = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.mixedGhosttyID, clock: clock)
            let act = SimFocusActuator(catalog: cat, allowRaise: true, allowAXFrontmost: false, allowActivateApp: false)
            let lad = LadderFocusSwitcher(actuator: act, catalog: cat, sleeper: VirtualSleeper(clock: clock), clock: clock)

            let outcome = await lad.focus(spotify)
            #expect(outcome == .failed(.unverified))
            let snap = await cat.snapshot()
            #expect(snap.frontmostPID == 1001)
            #expect(snap.focusedWindowID == Rig.mixedGhosttyID)
        }

        // 2. Wrong raise followed by staleCandidate still rolls back focus before returning .failed(.staleCandidate) (TRG2-02)
        actor WrongRaiseThenStaleActuator: FocusActuator {
            let catalog: SimWindowCatalogService
            var targetCalls = 0
            var rollbackCalls = 0

            init(catalog: SimWindowCatalogService) {
                self.catalog = catalog
            }

            func windows(of pid: Int32) async -> [AXWindowCandidate] {
                let list = await catalog.windows(of: pid)
                return list.enumerated().map { idx, win in
                    AXWindowCandidate(index: idx, windowID: win.windowID, frame: win.bounds, isMinimized: false, subrole: "AXStandardWindow")
                }
            }

            func perform(_ step: FocusStep, pid: Int32, window: AXWindowCandidate) async -> FocusStepResult {
                if window.windowID == Rig.mixedGhosttyID {
                    rollbackCalls += 1
                    await catalog.focusWindow(id: Rig.mixedGhosttyID)
                    return .performed
                }
                targetCalls += 1
                if targetCalls == 1 {
                    await catalog.focusWindow(id: Rig.mixedChrome1ID)
                    return .performed
                }
                return .staleCandidate
            }
        }

        let clock2 = VirtualClock(startAt: 0)
        let cat2 = SimWindowCatalogService(windows: Rig.mixedApps.windows, focusedWindowID: Rig.mixedGhosttyID, clock: clock2)
        let act2 = WrongRaiseThenStaleActuator(catalog: cat2)
        let lad2 = LadderFocusSwitcher(actuator: act2, catalog: cat2, sleeper: VirtualSleeper(clock: clock2), clock: clock2)
        let chrome2 = Rig.mixedApps.windows.first { $0.windowID == Rig.mixedChrome2ID }!

        let staleOutcome = await lad2.focus(chrome2)
        #expect(staleOutcome == .failed(.staleCandidate))
        #expect(await act2.rollbackCalls >= 1)
        let finalSnap = await cat2.snapshot()
        #expect(finalSnap.focusedWindowID == Rig.mixedGhosttyID)
        #expect(finalSnap.frontmostPID == 1001)
    }

    @Test("T92 cross-PID 8-poll window handles 0.2s activation latency while same-PID stays at 3 polls")
    func t92ActivationLatencyPollsCrossVsSamePID() async {
        let windows = Rig.mixedApps.windows
        let spotify = windows.first { $0.windowID == Rig.mixedSpotifyID }!
        let chrome1 = windows.first { $0.windowID == Rig.mixedChrome1ID }!
        let chrome2 = windows.first { $0.windowID == Rig.mixedChrome2ID }!

        // 1. Cross-PID with 0.2s activation latency succeeds on rungB with exact 3 steps and 0 rollbacks
        let clock1 = VirtualClock(startAt: 0)
        let cat1 = SimWindowCatalogService(windows: windows, focusedWindowID: Rig.mixedGhosttyID, clock: clock1)
        let act1 = SimFocusActuator(catalog: cat1, activationLatencySeconds: 0.2)
        let lad1 = LadderFocusSwitcher(actuator: act1, catalog: cat1, sleeper: VirtualSleeper(clock: clock1), clock: clock1)

        let outcome = await lad1.focus(spotify)
        #expect(outcome == .switched(.rungB))
        let calls1 = await act1.performCalls
        #expect(calls1.count == 3)
        #expect(calls1.allSatisfy { $0.candidate.windowID == Rig.mixedSpotifyID })

        // 2. Same-PID switch takes at most 3 verification snapshots per rung (1 initial + 3*3 polls + 1 rollback = 11)
        actor CountingCatalog: WindowCatalogService {
            let inner: SimWindowCatalogService
            private(set) var snapshotCalls = 0
            init(inner: SimWindowCatalogService) { self.inner = inner }
            func snapshot() async -> WindowSnapshot {
                snapshotCalls += 1
                return await inner.snapshot()
            }
        }

        let clock2 = VirtualClock(startAt: 0)
        let baseCat2 = SimWindowCatalogService(windows: windows, focusedWindowID: chrome1.windowID, clock: clock2)
        let countingCat = CountingCatalog(inner: baseCat2)
        let act2 = SimFocusActuator(catalog: baseCat2, failAllSwitches: true)
        let lad2 = LadderFocusSwitcher(actuator: act2, catalog: countingCat, sleeper: VirtualSleeper(clock: clock2), clock: clock2)

        #expect(await lad2.focus(chrome2) == .failed(.unverified))
        #expect(await countingCat.snapshotCalls == 11)
    }

    @Test("T93 alreadyFocused requires matching frontmostPID as well as focusedWindowID")
    func t93AlreadyFocusedRequiresMatchingFrontmostPID() async {
        actor SplitCatalog: WindowCatalogService {
            private let windows = Rig.mixedApps.windows
            private var frontPID: Int32 = 1001 // Ghostty frontmost while focusedWindowID says Spotify
            private var focusedID: UInt32 = Rig.mixedSpotifyID

            func snapshot() async -> WindowSnapshot {
                WindowSnapshot(
                    windows: windows,
                    frontmostPID: frontPID,
                    frontmostBundleID: frontPID == 1001 ? "com.mitchellh.ghostty" : "com.spotify.client",
                    focusedWindowID: focusedID,
                    takenAt: 0
                )
            }

            func windows(of pid: Int32) -> [WindowDescriptor] {
                windows.filter { $0.pid == pid }
            }

            func bringFrontmost(pid: Int32, windowID: UInt32) {
                frontPID = pid
                focusedID = windowID
            }
        }

        actor SplitActuator: FocusActuator {
            let catalog: SplitCatalog
            private(set) var performCalls: [FocusStep] = []
            init(catalog: SplitCatalog) { self.catalog = catalog }

            func windows(of pid: Int32) async -> [AXWindowCandidate] {
                await catalog.windows(of: pid).enumerated().map { idx, w in
                    AXWindowCandidate(index: idx, windowID: w.windowID, frame: w.bounds)
                }
            }

            func perform(_ step: FocusStep, pid: Int32, window: AXWindowCandidate) async -> FocusStepResult {
                performCalls.append(step)
                if step == .setAppFrontmost, let wid = window.windowID {
                    await catalog.bringFrontmost(pid: pid, windowID: wid)
                }
                return .performed
            }
        }

        let cat = SplitCatalog()
        let act = SplitActuator(catalog: cat)
        let lad = LadderFocusSwitcher(actuator: act, catalog: cat, sleeper: VirtualSleeper(clock: nil))
        let spotify = Rig.mixedApps.windows.first { $0.windowID == Rig.mixedSpotifyID }!

        let outcome = await lad.focus(spotify)
        #expect(outcome == .switched(.rungB))
        #expect(await act.performCalls == [.raiseAndMakeMain, .setAppFrontmost, .raiseAndMakeMain])
        let finalSnap = await cat.snapshot()
        #expect(finalSnap.frontmostPID == spotify.pid)
        #expect(finalSnap.focusedWindowID == spotify.windowID)
    }
}
