# Code Review, Round 1 (`code-reviewer`)

- **Commit reviewed:** `fb078be3ba8e161701e8ca7784259caa241eaf1e` (builder post #14, plan `docs/plans/final-plan-r1.md`)
- **Gate re-run:** `IFOCUS_SBX_OUT=/tmp/ifocus-cr scripts/sbx.sh test` gave **54 tests in 17 suites passed**, 0 compiler warnings under `-swift-version 6`.
- **Extra evidence:** three behavioural probes compiled against `/tmp/ifocus-cr/iFocusCore.o` (source: `~/.gemini/jetski/brain/18342d6b-008a-40b6-8c3c-57130d197f10/scratch/probe/main.swift`). Output:

```text
P1 match with IDs present but target absent: ambiguous(index: 0, count: 2)
P2 commit within 3 s with 1-in-6 outliers on neighbour: NEVER
P2b control: commit to 2 at 0.45
P3 after start();stop(): estimator starts=1 stops=1 streamStillLive=true
```

## Verdict

**No P0. Four P1 and ten P2 findings.** The pure core is solid: the coordinate maths is correct, the safety policy matches the plan, and the calibration stays numerically stable. The defects sit in the async shell and the native layer, which no headless test reaches: a start/stop race that leaves the camera on, an unbounded in-memory log, a calibration overlay that can trap the user, and AX calls that can stall the pipeline for many seconds.

| Severity | Count | IDs |
|---|---|---|
| P0 | 0 | |
| P1 | 4 | CR-01, CR-02, CR-03, CR-04 |
| P2 | 10 | CR-05 to CR-14 |
| P3 | 10 | CR-15 to CR-24 |

## What was verified correct (no action)

| Area | Evidence |
|---|---|
| Quartz vs AppKit Y axis | Every piece of logic stays in global Quartz (`CGWindowList` bounds, `CGDisplayBounds`, AX position). There is exactly one flip, `CoordinateSpace.cocoaRect` (`CoordinateSpace.swift:8-11`), and it uses `CGDisplayBounds(CGMainDisplayID()).height` (`CGDisplayTopologyService.swift:25-26`). The HUD uses it (`HUDController.swift:76`). T02 hand-checks the built-in panel at 1440 versus 1117. The overlay draws in `NSScreen.frame` with `(1 - v)` (`CalibrationOverlay.swift:85-86`), and the mapper inverts it with `minY + v * height` (`CalibrationMapper.swift:153-154`). Correct on panels of unequal height. |
| Typing lock privacy | Only `CGEventSource.secondsSinceLastEventType` and `buttonState` are read (`SystemInputActivityProvider.swift:12-35`). No tap, no key codes. |
| Ridge solver | Cholesky with a positive-pivot guard and finite checks (`RidgeSolver.swift:58-99`). The bias is unpenalised, the deviation floors are in place (`CalibrationSolver.swift:327-330`), and hull area, MAD rejection and LOTO CV all match the plan. |
| Safety precedence | Matches plan 4.6 exactly (`SafetyPolicy.swift:7-68`). T26 checks every veto alone and stacked. |
| Swift 6 isolation | It compiles warning-free. The two `@unchecked Sendable` types are queue-confined and documented. The camera session is never captured in a `@Sendable` closure. |

## P1 findings

### CR-01: `FocusCoordinator` start/stop race leaves the camera running after pause, lock or quit
- **Where:** `Sources/iFocusCore/Engine/FocusCoordinator.swift:120-156`. Callers: `AppController.swift:212-221`, `264-272`, `279-280`, `356-363`.
- **Problem:** `stop()` sets `isRunning = false`, calls `gazeEstimator.stop()`, then awaits `runTask`. `runUntilStreamFinishes()` has two suspension points (`topologyService.current()`, `windowCatalog.snapshot()`, lines 137-138) before it calls `gazeEstimator.start()` (line 142). If `stop()` lands in that window, the estimator is stopped *before* it starts. The task then starts the camera, breaks on the first event (line 144), and returns. Nobody ever stops the camera. Line 136 also re-sets `isRunning = true` unconditionally. A second variant: `start()` called while `stop()` is suspended overwrites `runTask` (line 123). `stop()` then awaits the *new* task, which never finishes, so `sessionTask` and Quit hang.
- **Reproduction:** probe P3 (`start(); stop()` with a catalog that takes 50 ms) gives `starts=1 stops=1 streamStillLive=true`. On the desk this happens when the pause hotkey is pressed twice quickly, or when the screen locks during startup. The camera light stays on while iFocus says "Paused" or the session is locked, and Vision keeps burning CPU into a dropped stream.
- **Fix:** add a run-generation token. `start()` increments `generation` and captures it. After `try await gazeEstimator.start()`, if `!isRunning || generation != captured`, call `await gazeEstimator.stop()` and return. Remove line 136. In `stop()`, cancel and await the captured task, never a re-read `runTask`. Alternatively, make start and stop one serialised state machine (`idle/starting/running/stopping`). Add a core test with a slow catalog and a recording estimator that asserts `isLive == false` after `start(); stop()`, and that `start()` during `stop()` does not hang.

### CR-02: Unbounded `decisionLog` growth in the resident agent
- **Where:** `FocusCoordinator.swift:42` (storage), appended at `182`, `196`, `223`, `236` for every gaze event.
- **Problem:** at 20 fps the menu-bar agent appends about 72 k entries an hour, roughly 1.7 M a day. Each `DecisionLogEntry` carries an `EngineAction` enum (with a `WindowDescriptor` payload and a `String` bundle ID on focus or mismatch). This is unbounded heap growth in a process meant to run for days. The log exists for T38 and `--simulate`; nothing in `--run` reads it.
- **Fix:** keep a ring buffer (for example the last 2 000 entries) or make logging opt-in (`init(recordDecisionLog: Bool = false)`, enabled by tests and simulation). Add a test that feeds 10 k events and asserts `log().count <= cap`.

### CR-03: The calibration overlay can trap the user (Esc needs a frame; no camera interruption handling; no watchdog)
- **Where:** `Sources/iFocusMac/UI/CalibrationOverlay.swift:160-164`, `208-240`. `Sources/iFocusMac/Gaze/CameraSession.swift` (whole file; there are no session notifications). `grep -rn "interrupt\|runtimeError" Sources` finds only the enum case and its consumers, so `GazeEvent.interrupted` is never produced.
- **Problem:** the overlay puts a borderless, mouse-opaque, 72 percent black window at `.screenSaver` level on **every** display (lines 219-236). Esc only sets `cancelled`, and that flag is checked only when the next `GazeEvent` arrives. If the camera stops delivering (an external webcam unplugged, the device taken by another process, an `AVCaptureSessionRuntimeError`, or sleep), the `for await` never wakes. Every screen stays covered until a force-quit. `NSApp.activate()` (line 239) can also be refused under macOS 14 cooperative activation, and then Esc never reaches the key window at all.
- **Fix:** (1) make `onEscape` call `Task { await gazeEstimator.stop() }`, which finishes the stream, as well as setting the flag. (2) Add a watchdog task that fails the run with `.cameraError("no frames for 5 s")` when no event arrives for N seconds. (3) In `CameraSession`, observe `AVCaptureSessionRuntimeErrorNotification`, `AVCaptureSessionWasInterruptedNotification` and `AVCaptureDeviceWasDisconnectedNotification` on the session queue, then yield `.interrupted(reason)` and finish. (4) Add a visible "Cancel" button so cancelling never depends on key focus.

### CR-04: AX calls can stall the whole pipeline for many seconds (the timeout applies only to the app element)
- **Where:** `Sources/iFocusMac/Focus/AXActuator.swift:20-28`, `41-69`. Header: `ApplicationServices.framework/.../AXUIElement.h:389-390` says "Setting the timeout on another accessibility object sets it only for that object".
- **Problem:** `AXUIElementSetMessagingTimeout(appElement, 0.25)` does not cover the window elements returned by `kAXWindowsAttribute`. Every per-window call (`_AXUIElementGetWindow`, position, size, minimised, subrole, raise, main, focused) uses the global default of about 6 s. A beach-balled terminal with five windows can block `AXActuator` for minutes: `windows()` makes about 5 calls per window, and the ladder enumerates three times plus re-validation in `perform`. `FocusCoordinator.processSingleEvent` awaits `focusSwitcher.focus`, so gaze processing, the status display and `stop()` (CR-01) all freeze with it.
- **Fix:** call `AXUIElementSetMessagingTimeout(element, 0.25)` on every window element right after fetching it, inside `fetchWindowElements`. Also put an overall deadline on `LadderFocusSwitcher.focus`: give up with `.failed(.unverified)` after about 1 s of cumulative actuator time.

## P2 findings

### CR-05: ID-aware matching falls back to geometry and raises a window whose ID is known to be wrong
- **Where:** `Sources/iFocusCore/Targeting/AXWindowMatcher.swift:9-37`.
- **Problem:** when the private resolver is active and the candidates carry IDs, but none equals the target (an AX list that is stale or partial, or a window AX does not expose), steps 2 to 5 still run over candidates that *have different known IDs*. With the measured V6 desk (9 Ghostty windows, 6 distinct frames), this returns `.ambiguous` and the ladder raises a terminal that is provably not the target. Verification then fails, but the wrong window is already key (see CR-06).
- **Reproduction:** probe P1 gives `ambiguous(index: 0, count: 2)` for candidates with IDs 111 and 222 when the target is 999.
- **Fix:** restrict geometric matching to candidates with `windowID == nil`. If any candidate carries an ID and none matches, return `.notFound`. Add this case to T29 and T30.

### CR-06: A failed ladder leaves focus on an unintended window (no rollback)
- **Where:** `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:33-75`. `FocusCoordinator.swift:233-249`.
- **Problem:** rungs B and C change the frontmost app, and C calls `NSRunningApplication.activate`, which surfaces that app's *own* key window, not necessarily the target. On `.failed(.unverified)` nothing restores the window that was focused before, so keystrokes now go to a window the user neither looked at nor chose. Backoff only stops retries.
- **Fix:** capture `initial.focusedWindowID` (already taken at line 20). On final failure, if the current focused ID differs from both the target and the initial ID, run rung A (or A and B) back to the initial window, and publish a mismatch flash on it. Add a sim test with `wrongWindowIDToRaise` that asserts focus returns to the original window.

### CR-07: One noisy sample on a neighbouring terminal resets dwell (starvation at shared edges)
- **Where:** `Sources/iFocusCore/Engine/FocusDecisionEngine.swift:97-105`.
- **Problem:** samples that land on nothing, or on a blocked window, are tolerated as dropouts for up to `candidateDropoutSeconds`. A single sample landing on a *different eligible* window replaces the pending candidate and restarts the dwell clock. With the 5 to 8 degree eye error the plan expects (section 14), gaze near the shared edge of two same-display tiles keeps resetting.
- **Reproduction:** probe P2. Gaze on B 60 pt from its edge with C, with 1 in 6 samples landing 60 pt inside C: no commit in 3 s. The control, with the same outlier rate on empty space, commits at 0.45 s.
- **Fix:** treat a challenger sample as a dropout of the current candidate. Keep a challenger timer, and replace the pending candidate only once the challenger has been supported for at least `candidateDropoutSeconds` (or two consecutive samples). Add an engine test like probe P2.

### CR-08: Verification proves z-order, not keyboard focus
- **Where:** `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:68-70`. `LadderFocusSwitcher.swift:78-89`.
- **Problem:** `focusedWindowID` is "the first layer-0 window of the frontmost PID" in CG order, with no size or eligibility filter. `kAXRaiseAction` reorders windows without guaranteeing key status, so verification can report `.switched` while keys still go to the old window. A small auxiliary layer-0 window of the app can also make a correct switch fail verification.
- **Fix:** in the native switcher, add a second check: read the application element's `kAXFocusedWindowAttribute`, resolve its window ID through `AXWindowID`, and require it to equal the target when the resolver is available. When computing `focusedWindowID`, skip windows below the 120x80 eligibility size.

### CR-09: Status published at 20 Hz churns the main thread and TCC
- **Where:** `FocusCoordinator.swift:189-193` (every frame), `260-283` (`permissionChecker()` runs `AVCaptureDevice.authorizationStatus` and `AXIsProcessTrusted` each frame). `AppController.swift:327-328`. `StatusMenuController.swift:91-127` (six title sets plus `NSImage(systemSymbolName:)` allocated each frame).
- **Fix:** publish `.status` only when `state`, `lastVeto`, `failureCount` or the candidate changes (or throttle to 2 Hz). Cache the permission state and refresh it at 1 Hz. Change the icon only when the pause state changes.

### CR-10: The per-PID bundle-ID cache is never invalidated (PID reuse means allowlist confusion)
- **Where:** `CGWindowCatalogService.swift:8`, `39-47`.
- **Problem:** `bundleIDCache[pid]` lives for the whole process lifetime. After a terminal quits and its PID is reused by a non-allowlisted app, that app's windows inherit an allowlisted bundle ID. They become focus targets and also satisfy `requireAllowedSource`. The cache also grows without bound.
- **Fix:** rebuild the cache per snapshot (one `NSRunningApplication` lookup per distinct PID is cheap), or key it by `(pid, launchDate)` and evict on `NSWorkspace.didTerminateApplicationNotification`.

### CR-11: The typing hold commits the moment typing pauses (copy-from-reference workflow)
- **Where:** `FocusDecisionEngine.swift:138-155` (follows plan 4.6 and 4.7, so this is a design-level item for triage).
- **Problem:** a common terminal workflow is reading a command in B while typing it into A. Dwell on B completes during typing, and the candidate is held. The first sample after a 1.0 s pause commits to B, so the rest of the command lands in B. The only warning is an amber flash every 2 s. T37 encodes this behaviour.
- **Fix (pick one):** after a `.typing` hold lifts, require a fresh dwell (reset `enteredAt` when the hold ends), or require `dwell + typingLockSeconds` of continuous post-typing gaze. Optionally make the mismatch border persist while the hold is active. Update T27 and T37 and record the change under Deviations.

### CR-12: No camera interruption or recovery in run mode
- **Where:** `CameraSession.swift:118-192` has no observers. `FocusCoordinator.swift:141-146` waits forever on a silent stream.
- **Problem:** if the camera is unplugged or interrupted, the coordinator keeps the menu at "Running" with a stale observation, and nothing restarts the session after the device returns.
- **Fix:** shares the plumbing in CR-03(3). On `.interrupted`, publish `.error`, stop, and retry with backoff (for example every 5 s, or on `AVCaptureDeviceWasConnectedNotification`).

### CR-13: Estimator re-entry orphans the previous stream
- **Where:** `VisionGazeEstimator.swift:45-57`. `CameraSession.swift:123-127`.
- **Problem:** a second `start()` while started overwrites `streamContinuation` and `activeContinuation` without calling `finish()`. Any consumer of the first stream never terminates (this is how CR-01's orphaned stream stays live).
- **Fix:** call `streamContinuation?.finish()` before replacing it, in both places.

### CR-14: `--run` startup and teardown are untested end to end
- **Where:** `IFocusCLI.swift:19`, `38`, `44`. `AppController.swift:100-113`.
- **Problem:** `NSApplication.run()` runs inside a `MainActor.run` job under `async main`. This usually works, but it nests the AppKit run loop inside a main-executor job. `shutdown()` can hang through CR-01, and the sandbox cannot exercise any of it.
- **Fix:** add a smoke step to the section 14 checklist (start, pause, resume, lock and unlock, quit within 2 s, camera light off when paused). Consider a synchronous `main()` that dispatches only `--doctor` and `--simulate` through `async`.

## P3 findings

| ID | Where | Issue | Fix |
|---|---|---|---|
| CR-15 | `LadderFocusSwitcher.swift:28`, `61` | Rung C is raise, `setAppFrontmost`, activate, where the plan says raise then activate. `lastRefusalWasStale` is set for any `perform == false`, not only for an identity mismatch. | Align with plan 4.8, or record it under Deviations. Have `perform` return a typed refusal. |
| CR-16 | `ScenarioRunner.swift:247-256`, `271` | `runPrepared` bypasses the ladder and hard-codes `.switched`, against plan section 7 ("through FocusPipeline and the ladder"). T35, T36, T37 and T44 never exercise matching or verification (T38 and T53 partly cover it). `seed: 0` is hard-coded in the result. | Route through `LadderFocusSwitcher` with `SimFocusActuator`, and pass `seed` through. |
| CR-17 | `EngineTests.swift:365-417` | The T51 coordinator half has no positive control. If the coordinator never emitted `.focus`, both runs would pass vacuously. | Add an unperturbed run that asserts `recordedTargets().count == 1`. |
| CR-18 | `FrameProcessor.swift:38-42` | A minimum-interval gate on a 30 fps camera with `cameraFPS = 20` processes every other frame, giving 15 fps. | Use an accumulator: `nextDue += 1/fps`, and process when `now >= nextDue - 5 ms`. |
| CR-19 | `CameraSession.swift:170-182` | `activeVideoMinFrameDuration` is checked against `activeFormat` before the preset commits, and the device is unlocked before `startRunning`, so the session preset can reset it. | Set it after `commitConfiguration`, and keep the lock across `startRunning`, or rely only on decimation. |
| CR-20 | `SimServices.swift:4-6` | `nonisolated(unsafe)` in `LockedBox` sidesteps the intent of invariant I4 (exactly two unchecked-sendable types). | List it as an explicit I4 exception in `check-invariants.sh` and the plan, or add `nonisolated(unsafe)` to the I4 grep. |
| CR-21 | `FrameProcessor.swift:165-175` | The de-roll sign is unverified. Vision's roll convention against lower-left `pointsInImage` coordinates is untested, and a wrong sign doubles the roll instead of cancelling it. | Derive the angle from the eye-corner line, or add a checklist step: tilt the head 15 degrees and confirm `eyeY` is unchanged. |
| CR-22 | `AppController.swift:279-322` | Calibrating calls `setPaused(false)` even when the user had paused before calibrating. | Restore the earlier pause state. |
| CR-23 | `WindowHitTester.swift:31-37` | Snap considers only eligible windows, so a gaze point in a gap nearer a browser still snaps to a terminal up to 80 pt away. | Snap only when the nearest window of any kind is eligible. |
| CR-24 | `AXWindowMatcher.swift:23-26`, `HUDController.swift:73-95` | (a) In public mode, `.ambiguous` may pick a hidden native-tab window that shares the frame, which switches tabs. (b) A new flash during a fade sets `alphaValue = 1` while the old animation still runs, so the flash is cut short. | (a) In public mode, refuse `.ambiguous` when the CG list has more than one on-screen same-frame window for that PID. (b) Start each flash inside `runAnimationGroup` with `duration = 0` before the fade. |

## Test-quality summary

The tests assert behaviour against independent expectations: a separate forward model, hand-computed flips, and table-driven vetoes. None are tautologies, apart from the T01 round trip, which the plan specifies. The gaps are exactly the async and native paths behind CR-01 to CR-07: no test covers the coordinator lifecycle, the log bound, the matcher with IDs present but the target absent, dwell reset by a neighbouring outlier, or ladder rollback. Each finding above names the test to add.
