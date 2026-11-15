# Round 1 Verification Triage (`triage-r1`)

- **Reviewed Commit:** `fb078be3ba8e161701e8ca7784259caa241eaf1e` (`main`)
- **Inputs Consolidated:**
  - `code-reviewer` (#15): `docs/reviews/code-review-r1.md` + `docs/reviews/code-review-r1.json` (`24` raw findings: `P0: 0, P1: 4, P2: 10, P3: 10`)
  - `sec-reviewer` (#16): `docs/reviews/sec-review-r1.md` + `docs/reviews/sec-review-r1.json` (`8` raw findings: `P0: 0, P1: 3, P2: 4, P3: 1`)
- **Triage Verification Run:** `IFOCUS_SBX_OUT=/tmp/ifocus-triage scripts/sbx.sh test` (**54/54 tests in 17 suites passed**) + `./scripts/check-invariants.sh` (**All invariants passed**). Every cited `file:line` was verified directly against `Sources/**`, `Tests/**`, `scripts/**`, `docs/plans/final-plan-r1.md`, and macOS SDK headers.
- **Scanner Gap Note:** `semgrep` failed inside the sandbox (`exit 2` reading `~/.semgrep/settings.yml`); `gitleaks` (`0` leads), `trivy` (`0` leads), `check-invariants.sh` (`I1`-`I7` pass), and full manual Swift/shell inspection covered the codebase.

---

## (a) Summary Counts by Disposition & Severity

Raw input count was `32` (`24` code-review + `8` security-review). Three exact duplicate pairs were merged (`CR-02`+`SEC-007`, `CR-10`+`SEC-005`, `CR-22`+`SEC-008`) and `CR-24` was split into `CR-24b` (`VALIDATED_ACTIONABLE` `P3`) and `CR-24a` (`DEFERRED_V2`), yielding **`30` deduplicated items**:

| Disposition | P0 | P1 | P2 | P3 | Unscored / Roadmap | Total |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **`VALIDATED_ACTIONABLE`** | 0 | 6 | 12 | 10 | 0 | **28** |
| **`REJECTED_FALSE_POSITIVE`** | 0 | 0 | 0 | 0 | 0 | **0** |
| **`DEFERRED_V2`** | 0 | 0 | 0 | 0 | 2 | **2** |
| **Total Deduplicated** | **0** | **6** | **12** | **10** | **2** | **30** |

### Deduplication & Severity Reconciliation Map

- **`TRG-07` (`P2`)** merges `CR-02` (`P1`) and `SEC-007` (`P2`) — unbounded `FocusCoordinator.decisionLog`. Reconciled to `P2` because short runs are unaffected while multi-day agent uptime leaks heap monotonically; still mandatory to fix in Round 2.
- **`TRG-12` (`P2`)** merges `CR-10` (`P2`) and `SEC-005` (`P2`) — uninvalidated `CGWindowCatalogService.bundleIDCache`.
- **`TRG-26` (`P3`)** merges `CR-22` (`P3`) and `SEC-008` (`P3`) — `AppController.runInteractiveCalibration()` unconditionally clears user pause state.
- **`CR-11` (`P2` -> `DEF-01`)** and **`CR-24a` (`P3` -> `DEF-02`)** conform to explicit Round 1 plan contracts (`docs/plans/final-plan-r1.md` §§2, 4.7, 4.8 and tests `T27`, `T30`, `T37`) and are logged under `DEFERRED_V2` rather than forcing unapproved spec churn in v1.

---

## (b) Validated Actionable Findings (`28`)

### P1 — High Defect / Security Risk (`6`)

#### `TRG-01` (`P1` | Source: `CR-01`) — `FocusCoordinator` start/stop race leaves camera live and can hang `stop()`
- **Where:** `Sources/iFocusCore/Engine/FocusCoordinator.swift:120-156`; callers in `Sources/iFocusMac/App/AppController.swift:212-221, 264-272, 279-280, 356-363`.
- **Verified Defect:** `runUntilStreamFinishes()` unconditionally sets `isRunning = true` (`line 136`) and suspends on `topologyService.current()` (`line 137`) and `windowCatalog.snapshot()` (`line 138`) before calling `gazeEstimator.start()` (`line 142`). If `stop()` executes during that window, `gazeEstimator.stop()` completes before `start()` runs; `runUntilStreamFinishes()` then starts the camera, breaks on the first event (`line 144`), and exits without stopping `gazeEstimator`. Conversely, `start()` called while `stop()` awaits `gazeEstimator.stop()` (`line 130`) overwrites `runTask` (`line 123`), causing `stop()` (`line 131`) to await the newly spawned live task and hang.
- **Fix Guidance:** Add a monotonic `runGeneration: UInt64` token (or serialised lifecycle state). Capture `generation` in `start()`, remove `isRunning = true` at `line 136`, and check `!isRunning || runGeneration != captured` after every suspension point and after `try await gazeEstimator.start()`, calling `await gazeEstimator.stop()` before returning. In `stop()`, cancel and await a local copy of `runTask` before clearing it.
- **Acceptance Test Criterion:** Add a `Coordinator` test with a slow `WindowCatalogService` (50 ms delay) and recording `GazeEstimator` proving (a) `start(); stop()` leaves `estimator.isLive == false`, and (b) `start()` invoked while `stop()` is awaiting estimator teardown completes `stop()` without hanging and settles cleanly.

#### `TRG-02` (`P1` | Source: `CR-03`) — `CalibrationOverlay` `.screenSaver` trap when camera stalls or key focus is refused
- **Where:** `Sources/iFocusMac/UI/CalibrationOverlay.swift:160-164, 208-240`; `Sources/iFocusMac/Gaze/CameraSession.swift:118-203`.
- **Verified Defect:** `CalibrationOverlay` creates borderless mouse-capturing windows at `.screenSaver` level across all displays (`lines 217-238`). `onEscape` only sets `self.cancelled = true` (`lines 229-231`), which is checked only after the next `GazeEvent` arrives (`line 161`). `CameraSession` registers zero session/device notifications, so a camera disconnect, runtime error, or interruption stalls `for await event in stream` indefinitely with all screens covered. Additionally, `NSApp.activate()` (`line 239`) can fail to gain key focus under macOS 14+ cooperative activation, leaving `Esc` undelivered.
- **Fix Guidance:** (1) Have `onEscape` immediately invoke `Task { @MainActor in await gazeEstimator.stop() }` (finishing the stream) alongside setting `cancelled = true`. (2) Add a clickable `"Cancel (Esc)"` `NSButton` on the overlay view wired to the same cancel action so exit never depends on key focus. (3) Observe `AVCaptureSessionRuntimeErrorNotification`, `AVCaptureSessionWasInterruptedNotification`, and `AVCaptureDeviceWasDisconnectedNotification` in `CameraSession` (yielding `.interrupted(reason)` and finishing the stream). (4) Add a no-frame watchdog task (e.g., 5 s) in `CalibrationOverlay.run` that aborts with `.cameraError(...)` if no frame arrives.
- **Acceptance Test Criterion:** Unit/integration test (using a stalled/silent `GazeEstimator` or mock stream + `CalibrationSession` / `CalibrationOverlay` cancellation path, plus `CameraSession` observer wiring verified in `iFocusMac` build) proving cancellation or a 5 s silent stream terminates `run(...)` promptly without hanging.

#### `TRG-03` (`P1` | Source: `CR-04`) — `AXActuator` messaging timeout set only on app element, leaving per-window calls at ~6 s default
- **Where:** `Sources/iFocusMac/Focus/AXActuator.swift:20-36, 39-81, 83-90`; verified against `AXUIElement.h:388-395`.
- **Verified Defect:** `AXUIElementSetMessagingTimeout(appElement, 0.25)` (`lines 21, 42`) applies only to `appElement`, not to child window `AXUIElement`s returned by `kAXWindowsAttribute`. Every per-window call (`_AXUIElementGetWindow`, `kAXPositionAttribute`, `kAXSizeAttribute`, `kAXMinimizedAttribute`, `kAXSubroleAttribute`, `kAXRaiseAction`, `kAXMainAttribute`, `kAXFocusedAttribute`) falls back to the ~6 s global default, allowing a single hung target app with 5 windows to block `LadderFocusSwitcher` and `FocusCoordinator` for minutes.
- **Fix Guidance:** Call `AXUIElementSetMessagingTimeout(element, 0.25)` on every `AXUIElement` returned in `fetchWindowElements(for:)` (`lines 83-90`), and enforce an overall cumulative wall-clock deadline (~1.0 s) across `LadderFocusSwitcher.focus(_:)`.
- **Acceptance Test Criterion:** Static/code verification that every element returned by `fetchWindowElements` receives `AXUIElementSetMessagingTimeout(..., 0.25)` before any attribute/action call, plus a `Ladder` unit test with a slow `FocusActuator` confirming `LadderFocusSwitcher.focus(_:)` aborts cleanly once the cumulative deadline is exceeded.

#### `TRG-04` (`P1` | Source: `SEC-001`) — `SystemSessionStateProvider` reactivates webcam and AX loop behind lock screen
- **Where:** `Sources/iFocusMac/Input/SystemSessionStateProvider.swift:7-84`; `Sources/iFocusMac/App/AppController.swift:32-98, 212-221`.
- **Verified Defect:** `activeLock` initializes to `true` (`line 7`) without querying WindowServer. `activateNames` (`lines 27-32`) binds `NSWorkspace.didWakeNotification`, `NSWorkspace.screensDidWakeNotification`, `NSWorkspace.sessionDidBecomeActiveNotification`, and `DistributedNotificationCenter` `"com.apple.screenIsUnlocked"` directly to `setActive(true)` (`line 42`). Waking the display for a notification while locked at `loginwindow` turns on the webcam and AX polling behind the lock screen; any local process can also spoof `DistributedNotificationCenter` posts. `AppController.runCalibrateCommand()` (`AppController.swift:32-98`) never observes session lock/sleep at all.
- **Fix Guidance:** Query authoritative WindowServer state via `CGSessionCopyCurrentDictionary()` (`CoreGraphics/CGSession.h`): require `(dict[kCGSessionOnConsoleKey as String] as? Bool ?? true) && !(dict["CGSSessionScreenIsLocked"] as? Bool ?? false)`. Track `isSystemSleeping` and `isDisplaySleeping` separately from `NSWorkspace` notifications, treat `DistributedNotificationCenter` posts only as triggers to re-query `CGSessionCopyCurrentDictionary()`, recompute active state on init and in `isSessionActive()`, and observe `SystemSessionStateProvider` in `runCalibrateCommand()` to abort calibration on lock/sleep.
- **Acceptance Test Criterion:** Unit test covering extracted pure session-state decision logic (sleep/display-wake while locked stays `active == false`; spoofed unlock while `CGSSessionScreenIsLocked == true` stays `active == false`; console unlock + awake transitions `active == true`), plus code verification of `CGSessionCopyCurrentDictionary()` in `SystemSessionStateProvider` and `runCalibrateCommand()`.

#### `TRG-05` (`P1` | Source: `SEC-002`) — `CGWindowCatalogService` drops `layer != 0` windows, blinding occlusion checks to modal and security dialogs
- **Where:** `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:27-37`; `Sources/iFocusCore/Targeting/WindowHitTester.swift:5-23`; `Sources/iFocusCore/Model/WindowTypes.swift:4-24`.
- **Verified Defect:** `CGWindowCatalogService.snapshot()` executes `guard let layer = (entry[kCGWindowLayer] as? NSNumber)?.intValue, layer == 0 else { continue }` (`line 28`). System auth prompts (`SecurityAgent`, `CoreAuthUI`), TCC dialogs (`UserNotificationCenter`), modal panels (`layer = 8`), floating overlays (`layer = 3`), and popup menus (`layer = 101`) sit at `layer > 0`, so `WindowHitTester` never sees them and switches focus into underlying terminals while the user reads the dialog.
- **Fix Guidance:** Add `public var layer: Int = 0` to `WindowDescriptor` (with backward-compatible `Codable` default `0`) and require `window.layer == 0` in `WindowHitTester.isEligible(_:config:)`. In `CGWindowCatalogService.snapshot()`, retain visible windows with `0 <= layer && layer <= Int(CGWindowLevelForKey(.screenSaverWindow))`, filtering out `ownPID`, status-bar strip items (`layer >= Int(CGWindowLevelForKey(.mainMenuWindow)) && bounds.height <= 36`), and transparent/non-occluding desktop chrome (`com.apple.WindowManager`, `com.apple.dock`, `com.apple.controlcenter`) so `layer > 0` dialogs act as `.blocked` occluders. Additionally veto switching globally whenever an on-screen security prompt (`com.apple.SecurityAgent`, `com.apple.LocalAuthentication.UIAgent`, `com.apple.UserNotificationCenter`, `com.apple.coreservices.uiagent`) is present in `snapshot.windows`.
- **Acceptance Test Criterion:** `HitTest` & `Safety` unit tests verifying (a) a `layer > 0` dialog window overlapping a terminal returns `.blocked` and is never eligible as a switch target, and (b) presence of an on-screen security prompt bundle ID in `snapshot.windows` vetoes switching across all displays.

#### `TRG-06` (`P1` | Source: `SEC-003`) — `SafetyPolicy` skips `Config.hardBlocklist` when `requireAllowedSource == false` and omits `CoreAuthUI`
- **Where:** `Sources/iFocusCore/Engine/SafetyPolicy.swift:44-46`; `Sources/iFocusCore/Model/Config.swift:16-26, 225-229`.
- **Verified Defect:** `DefaultSafetyGuardPolicy.evaluate(_:)` (`SafetyPolicy.swift:44`) only calls `config.isBundleAllowed(context.frontmostBundleID)` when `context.config.requireAllowedSource == true`, completely bypassing `Config.hardBlocklist` when `requireAllowedSource == false`. Additionally, `Config.hardBlocklist` (`Config.swift:16-26`) omits `com.apple.LocalAuthentication.UIAgent`, `com.apple.UserNotificationCenter`, `com.apple.ScreenSharing`, and `com.apple.Settings`.
- **Fix Guidance:** Enforce `if let front = context.frontmostBundleID, Config.hardBlocklist.contains(front) { return .deny(.sourceNotAllowed) }` unconditionally before the `requireAllowedSource` check in `DefaultSafetyGuardPolicy.evaluate(_:)`, and add the four omitted bundle IDs to `Config.hardBlocklist`.
- **Acceptance Test Criterion:** Unit tests in `SafetyTests` proving `hardBlocklist` (including `com.apple.LocalAuthentication.UIAgent`, `com.apple.UserNotificationCenter`, `com.apple.ScreenSharing`, `com.apple.Settings`) still returns `.deny(.sourceNotAllowed)` when `config.requireAllowedSource == false`.

---

### P2 — Worthwhile Engineering & Security Hardening (`12`)

#### `TRG-07` (`P2` | Merged: `CR-02` + `SEC-007`) — Unbounded `FocusCoordinator.decisionLog` growth
- **Where:** `Sources/iFocusCore/Engine/FocusCoordinator.swift:42, 182-188, 196-202, 223-229, 236-242`.
- **Verified Defect:** `decisionLog` appends a `DecisionLogEntry` on every 20-30 Hz gaze event (~1.7M-2.6M entries/day) with no cap or eviction, even though `AppController` never reads `coordinator.log()`.
- **Fix Guidance:** Bound `decisionLog` to a configurable capacity (e.g., `maxDecisionLogEntries: Int = 4096` ring buffer, evicting oldest entries when exceeded; `4096` exceeds 60 s simulations of `1,201` steps so `T38` passes unchanged), or make logging opt-in for test/sim callers.
- **Acceptance Test Criterion:** `Coordinator` unit test feeding `> 5,000` events into `FocusCoordinator` and asserting `await coordinator.log().count <= cap` while `T38` remains green.

#### `TRG-08` (`P2` | Source: `CR-05`) — `AXWindowMatcher` falls back to geometry over candidates with different known IDs
- **Where:** `Sources/iFocusCore/Targeting/AXWindowMatcher.swift:9-37`.
- **Verified Defect:** After exact `windowID` match fails (`line 9`), geometric and approximate matching (`lines 13-35`) include candidates whose `windowID` is non-nil and unequal to `target.windowID`, picking a provably wrong window (`probe P1` returned `.ambiguous(index: 0, count: 2)` when target was `999` and candidates had IDs `111`, `222`).
- **Fix Guidance:** Filter geometric and approximate matching to candidates where `candidate.windowID == nil`. If all candidates have non-nil `windowID` and none equals `target.windowID`, return `.notFound`.
- **Acceptance Test Criterion:** `AXMatchTests` (`T29`/`T30`) test case with non-nil mismatched candidate IDs sharing `target.bounds` asserting `AXWindowMatcher.match` returns `.notFound`.

#### `TRG-09` (`P2` | Source: `CR-06`) — `LadderFocusSwitcher` has no rollback when failed rungs leave focus on unintended window
- **Where:** `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:20, 33-75`; `Sources/iFocusCore/Engine/FocusCoordinator.swift:233-249`.
- **Verified Defect:** Rungs B and C activate/frontmost the target app, which can surface a different key window of that app. When verification fails after rung C, `LadderFocusSwitcher.focus` returns `.failed(...)` without restoring `initial.focusedWindowID`, leaving user keystrokes aimed at the wrong window.
- **Fix Guidance:** On final failure, inspect the current snapshot; if `current.focusedWindowID != target.windowID` and `current.focusedWindowID != initial.focusedWindowID`, and `initialWindow` exists in `initial.windows`, perform a single bounded rollback attempt toward `initialWindow` and emit an amber mismatch alert if desired. Ensure `SimFocusActuator` in `T32` still reports `.failed(.unverified)`.
- **Acceptance Test Criterion:** `Ladder` test (with a simulated actuator that activates the wrong window on target switch and restores cleanly on rollback) asserting `focus(_:)` returns `.failed(.unverified)` AND `catalog.snapshot().focusedWindowID == initialFocusedID`, while `T32` remains green.

#### `TRG-10` (`P2` | Source: `CR-07`) — Single noisy sample on neighbouring eligible window resets dwell immediately
- **Where:** `Sources/iFocusCore/Engine/FocusDecisionEngine.swift:97-105`.
- **Verified Defect:** Dropouts to empty space or blocked windows are tolerated for `candidateDropoutSeconds` (`0.12 s`), but a single 50 ms outlier on a neighbouring eligible terminal (`pending?.target.windowID != target.windowID`, `line 97`) immediately replaces `pending` and resets `enteredAt`, causing dwell starvation near shared tile edges (`probe P2`).
- **Fix Guidance:** Track a challenger candidate (`challenger: PendingCandidate?`); treat samples on a different eligible window as a dropout for the active `pending` candidate while accumulating challenger dwell, replacing `pending` only once the challenger persists for `>= config.candidateDropoutSeconds` (or if `pending` expires).
- **Acceptance Test Criterion:** `EngineTests` test matching probe P2 (1-in-6 outlier samples on neighbouring terminal C while dwelling on B) asserting B commits near expected dwell (~0.45 s) rather than starving, while `T20` and `T44` pass unchanged.

#### `TRG-11` (`P2` | Source: `CR-08`) — Verification checks CG z-order only (ignores key status and sub-eligible window sizes)
- **Where:** `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:68-70`; `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:78-89`; `Sources/iFocusMac/Focus/AXActuator.swift`.
- **Verified Defect:** `CGWindowCatalogService.focusedWindowID` returns the first window of `frontmostPID` in CG order without size/layer eligibility checks, and `LadderFocusSwitcher.verifyFocused` checks only `snap.focusedWindowID == windowID` (z-order), not AX keyboard-focus (`kAXFocusedWindowAttribute`).
- **Fix Guidance:** In `CGWindowCatalogService.snapshot()`, compute `focusedWindowID` from `layer == 0` windows with `bounds.width >= 120 && bounds.height >= 80` (falling back to any `layer == 0` window of `frontmostPID` only if none meet size). In `AXActuator` / native verification, expose an optional post-switch key-window check reading `kAXFocusedWindowAttribute` on `appElement` and verifying via `AXWindowID` (when private resolver is active) that it matches `target.windowID`.
- **Acceptance Test Criterion:** Unit test verifying small `< 120x80` auxiliary windows do not mask `focusedWindowID` or falsely satisfy `verifyFocused`, plus native `AXActuator` verification check wired into `TrustedFocusSwitcher` / `LadderFocusSwitcher`.

#### `TRG-12` (`P2` | Merged: `CR-10` + `SEC-005`) — Uninvalidated PID-keyed `bundleIDCache` allows PID-wraparound misclassification
- **Where:** `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:8, 39-47`.
- **Verified Defect:** `bundleIDCache: [Int32: String]` persists for the full process lifetime without termination eviction or `launchDate` comparison. After PID wraparound (`PID_MAX = 99999`), an unrelated or blocklisted app reusing an exited terminal's PID inherits the cached allowlisted terminal bundle ID.
- **Fix Guidance:** Replace the persistent `bundleIDCache` property with a local per-`snapshot()` `[Int32: String?]` dictionary (resolving `NSRunningApplication(processIdentifier:)` once per unique on-screen PID per 200 ms snapshot).
- **Acceptance Test Criterion:** Code inspection confirms zero persistent PID-only `bundleIDCache` in `CGWindowCatalogService`, and `iFocusMac` compiles warning-free under Swift 6.

#### `TRG-13` (`P2` | Source: `CR-09`) — 20 Hz status publishing runs TCC checks, menu updates, and `NSImage` allocation every frame
- **Where:** `Sources/iFocusCore/Engine/FocusCoordinator.swift:189-193, 260-283`; `Sources/iFocusMac/App/AppController.swift:327-328`; `Sources/iFocusMac/UI/StatusMenuController.swift:91-127`.
- **Verified Defect:** Every `.none` frame (`20 Hz`) invokes `publishStatus`, calling `permissionChecker()` (`AVCaptureDevice.authorizationStatus` + `AXIsProcessTrusted`), emitting `.status`, updating 6 `NSMenuItem` titles, and creating a new `NSImage(systemSymbolName:)` on the main thread even though the menu does not display `dwellProgress` or `candidateWindowID`.
- **Fix Guidance:** Publish `.status` only when `(state, lastVeto, failureCount, detail)` changes (or throttle unchanged periodic refreshes); cache `permissionChecker()` results in `FocusCoordinator` with a 1.0 s TTL; in `StatusMenuController`, cache the last `paused` state / status tuple and update `statusItem.button` icon and menu items only on actual change.
- **Acceptance Test Criterion:** `Coordinator` unit test confirming `permissionChecker` is called at most ~1 Hz during a 20 Hz event stream and duplicate identical `.status` events are suppressed.

#### `TRG-14` (`P2` | Source: `CR-12`) — No camera interruption/disconnect recovery in run mode
- **Where:** `Sources/iFocusMac/Gaze/CameraSession.swift:118-192`; `Sources/iFocusCore/Engine/FocusCoordinator.swift:141-156`; `Sources/iFocusCore/Engine/FocusPipeline.swift:63-73`.
- **Verified Defect:** `CameraSession` lacks interruption/runtime-error/disconnect observers, and `FocusCoordinator.runUntilStreamFinishes()` exits the `for await` loop silently when a stream terminates or yields `.interrupted`, leaving the menu showing `"Running"` without retrying when the camera returns.
- **Fix Guidance:** Sharing the `CameraSession` notification plumbing from `TRG-02`, handle `.interrupted(reason)` in `FocusCoordinator.runUntilStreamFinishes()` by stopping the estimator, publishing `.status(state: .error, detail: reason)`, and scheduling a backoff retry (e.g., 5 s timer or `AVCaptureDeviceWasConnectedNotification` in `AppController`) while not paused and session active.
- **Acceptance Test Criterion:** `Coordinator` unit test with a mock `GazeEstimator` emitting `.interrupted("disconnected")` and finishing the stream asserting `CoordinatorEvent.status` with `state == .error` is emitted and camera restarts cleanly on retry.

#### `TRG-15` (`P2` | Source: `CR-13`) — Estimator/session re-entry orphans previous `AsyncStream.Continuation`
- **Where:** `Sources/iFocusMac/Gaze/VisionGazeEstimator.swift:45-57`; `Sources/iFocusMac/Gaze/CameraSession.swift:123-127`.
- **Verified Defect:** Calling `start()` while already started overwrites `streamContinuation` / `activeContinuation` without calling `.finish()` on the prior continuation, stranding any active consumer of the first `AsyncStream`.
- **Fix Guidance:** Call `streamContinuation?.finish()` (in `VisionGazeEstimator.start()`) and `activeContinuation?.finish()` (in `CameraSession.startOnQueue()`) before replacing them.
- **Acceptance Test Criterion:** Code verification of `.finish()` before replacement in both `VisionGazeEstimator` and `CameraSession`, plus warning-free Swift 6 build.

#### `TRG-16` (`P2` | Source: `CR-14`) — `--run` / `--calibrate` AppKit lifecycle runs `NSApp.run()` inside `async main` `MainActor.run` without lifecycle smoke check
- **Where:** `Sources/iFocusApp/IFocusCLI.swift:10-45`; `Sources/iFocusMac/App/AppController.swift:100-113`.
- **Verified Defect:** `IFocusCLI.main()` is `async` and wraps `AppController.runAgentCommand()` (`app.run()`) inside `await MainActor.run`, nesting AppKit's blocking run loop inside a Swift concurrency main-executor job, and no end-to-end lifecycle smoke step exists in the checklist.
- **Fix Guidance:** Convert `IFocusCLI` to synchronous `static func main()` that calls `AppController.runAgentCommand()` / `runCalibrateCommand()` and `runSimulate(...)` directly on the main thread, bridging only `--doctor` via `RunLoop`/semaphore or `DispatchQueue` + `Task`. Add start/pause/resume/lock/unlock/quit-within-2s smoke verification to the on-desk checklist in `README.md`.
- **Acceptance Test Criterion:** `sbx.sh build` + `--simulate all` + `--doctor` + `--help`/`--version` exit cleanly (`0`) after synchronous `main()` refactor, and `README.md` checklist includes the lifecycle smoke steps.

#### `TRG-17` (`P2` | Source: `SEC-004`) — Build and signing scripts use predictable shared `/tmp` directories without UID/symlink/mode checks
- **Where:** `scripts/sbx.sh:4-6, 25-34`; `scripts/bundle-app.sh:17-27, 32-40`.
- **Verified Defect:** Default `IFOCUS_SBX_OUT=/tmp/ifocus-sbx` and hardcoded `/tmp/ifocus-build`, `/tmp/clang-cache`, `/tmp/swiftpm-cache`, `/tmp/swift-modcache` are created with bare `mkdir -p` inside sticky `/tmp` without rejecting symlinks (`-L`), verifying UID ownership (`-O`), or enforcing `0700` before compiling, executing `$OUT/tests`, or passing `$BIN_PATH` to `codesign`.
- **Fix Guidance:** Default scratch/cache paths in both scripts to `$(id -u)`-scoped paths (e.g., `/tmp/ifocus-sbx-$(id -u)`) and run a `prepare_secure_dir()` helper (`mkdir -p -m 0700`, abort if `[ -L "$d" ] || [ ! -d "$d" ] || [ ! -O "$d" ]`, then `chmod 0700 "$d"`) on every scratch/cache path before use.
- **Acceptance Test Criterion:** Both `scripts/sbx.sh test` and `scripts/bundle-app.sh` pass with UID-scoped `0700` directories and reject a symlinked scratch directory (`exit 1`) in a quick shell check.

#### `TRG-18` (`P2` | Source: `SEC-006`) — `SecureFileStore.read()` accepts group/world-writable directories and uses path-based TOCTOU
- **Where:** `Sources/iFocusCore/Storage/SecureFileStore.swift:57-80, 134-160, 200-217`.
- **Verified Defect:** `validateDirectoryStat(..., fixPermissions: false)` (`lines 67, 210-216`) silently accepts `0o775`/`0o777` directories during `read()`, and `read()`/`write()` re-resolve directory paths across `lstat`/`chmod`/`open`/`rename`/`unlink` instead of pinning a directory descriptor.
- **Fix Guidance:** Throw `SecureFileStoreError.insecureDirectory` in `validateDirectoryStat` when `(perms & 0o077) != 0` and `!fixPermissions`. Open the directory once via `open(dirPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`, `fstat(dirFD, ...)` (and `fchmod(dirFD, ...)` when fixing), and perform `openat`, `renameat`, and `unlinkat` relative to `dirFD`.
- **Acceptance Test Criterion:** Extend `T34` in `Tests/iFocusCoreTests/FileStoreTests.swift` to verify `chmod 0o775` or `0o777` on the store directory causes `store.read(...)` to throw `SecureFileStoreError.insecureDirectory(...)`.

---

### P3 — Optional Polish & Hardening (`10`)

#### `TRG-19` (`P3` | Source: `CR-15`) — `LadderFocusSwitcher` Rung C divergence and broad `lastRefusalWasStale`
- **Where:** `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:28, 56-68, 75`; `docs/plans/final-plan-r1.md:476, 480`.
- **Verified Defect:** Rung C executes `[.raiseAndMakeMain, .setAppFrontmost, .activateApp]` instead of plan §4.8's `[.raiseAndMakeMain, .activateApp]`, and `lastRefusalWasStale = true` is set for any `perform(...) == false` rather than distinguishing identity mismatch (`staleCandidate`) from other actuator refusals.
- **Fix Guidance:** Align Rung C with plan §4.8 (or document under Deviations) and distinguish identity-mismatch refusals cleanly (e.g., typed refusal or checking `perform` semantics).
- **Acceptance Test Criterion:** `T31` and `T45` pass after aligning Rung C / stale refusal semantics.

#### `TRG-20` (`P3` | Source: `CR-16`) — `ScenarioRunner.runPrepared` bypasses ladder and hard-codes `seed: 0`
- **Where:** `Sources/iFocusCore/Simulation/ScenarioRunner.swift:247-256, 271`; `docs/plans/final-plan-r1.md` §7.
- **Verified Defect:** `runPrepared` hard-codes `.switched(strategy)` and `focusLocally` instead of exercising `LadderFocusSwitcher` + `SimFocusActuator`, and sets `seed: 0` in `ScenarioResult` (`line 271`) even when `run(_:seed:)` passes a non-zero seed.
- **Fix Guidance:** Store `seed` on `PreparedScenario` and propagate it to `ScenarioResult`, and route `runPrepared` switches through `LadderFocusSwitcher` + `SimFocusActuator` (or add a dedicated ladder-backed runner used by `ScenarioTests`).
- **Acceptance Test Criterion:** `ScenarioResult.seed` matches the caller's `seed` in `T35`, and `T35`-`T38`, `T44`, `T53` pass through `LadderFocusSwitcher`.

#### `TRG-21` (`P3` | Source: `CR-17`) — `T51` coordinator check lacks unperturbed positive control
- **Where:** `Tests/iFocusCoreTests/EngineTests.swift:365-417`.
- **Verified Defect:** Both sub-runs in `T51`'s coordinator half assert `recordedTargets().isEmpty` without an unperturbed control proving the same setup yields `1` switch when `confirm` is not tripped.
- **Fix Guidance:** Add an unperturbed third run inside `T51` asserting `recordedTargets().count == 1`.
- **Acceptance Test Criterion:** `T51` passes with positive control `count == 1` and both abort cases `isEmpty`.

#### `TRG-22` (`P3` | Source: `CR-18`) — `FrameProcessor` min-interval gate decimates 30 fps camera to ~15 fps at `cameraFPS = 20`
- **Where:** `Sources/iFocusMac/Gaze/FrameProcessor.swift:38-42`.
- **Verified Defect:** `(now - last) < (1/20 - 5 ms) = 45 ms` drops every second 33.3 ms frame from a 30 fps camera, yielding 15 fps instead of 20 fps.
- **Fix Guidance:** Use a phase-locked accumulator (`nextDue += 1.0 / Double(targetFPS)`, processing when `now >= nextDue - 0.005` and resetting if `now - nextDue > 0.25`).
- **Acceptance Test Criterion:** Code verification (or extracted pure decimation helper unit test) proving 30 Hz timestamps yield ~20 accepted frames/s at `targetFPS = 20`.

#### `TRG-23` (`P3` | Source: `CR-19`) — `CameraSession` sets frame duration before `commitConfiguration()` and unlocks before `startRunning()`
- **Where:** `Sources/iFocusMac/Gaze/CameraSession.swift:170-188`.
- **Verified Defect:** `device.activeFormat` is queried before `commitConfiguration()` applies `sessionPreset`, and `unlockForConfiguration()` runs before `startRunning()`.
- **Fix Guidance:** Move `activeVideoMinFrameDuration` configuration after `newSession.commitConfiguration()`, or hold the configuration lock until `startRunning()` completes (falling back cleanly to `FrameProcessor` decimation).
- **Acceptance Test Criterion:** Code verification in `CameraSession.swift` + warning-free Swift 6 build.

#### `TRG-24` (`P3` | Source: `CR-20`) — `LockedBox` uses `nonisolated(unsafe)` outside `Sources/iFocusMac/Gaze/`
- **Where:** `Sources/iFocusCore/Simulation/SimServices.swift:4-6`; `scripts/check-invariants.sh:70-83`.
- **Verified Defect:** `LockedBox` uses `nonisolated(unsafe) private var storage: Value` (protected by `NSLock` because `iFocusCore` restricts imports to `Foundation`/`CoreGraphics`), bypassing `check-invariants.sh` I4's `@unchecked Sendable` grep.
- **Fix Guidance:** Extend `scripts/check-invariants.sh` I4 check to inspect `nonisolated(unsafe)` and declare `SimServices.swift:6` (`LockedBox`) as an explicit audited exception (also noted in `final-plan-r1.md` / `docs/build-r2.md`).
- **Acceptance Test Criterion:** `./scripts/check-invariants.sh` checks both `@unchecked Sendable` and `nonisolated(unsafe)` and exits `0`.

#### `TRG-25` (`P3` | Source: `CR-21`) — Eye de-roll sign convention (`-roll`) unverified against Vision `pointsInImage`
- **Where:** `Sources/iFocusMac/Gaze/FrameProcessor.swift:165-175`.
- **Verified Defect:** `cos(-roll)` / `sin(-roll)` assumes Vision's roll sign matches lower-left `pointsInImage` rotation without an on-desk verification step or geometric eye-corner derivation.
- **Fix Guidance:** Derive the eye-axis angle directly from the eye-contour outer/inner corners (invariant to Vision `roll` sign), or add a 15-degree head-tilt check to `README.md`'s on-desk checklist.
- **Acceptance Test Criterion:** Either inter-canthal rotation tested in a `CoreGraphics` geometry test or explicit head-tilt verification added to `README.md`.

#### `TRG-26` (`P3` | Merged: `CR-22` + `SEC-008`) — Cancelled/failed interactive calibration unpauses a user-paused agent
- **Where:** `Sources/iFocusMac/App/AppController.swift:274-323`.
- **Verified Defect:** `runInteractiveCalibration()` calls `await coordinator.setPaused(true)` (`line 279`) without saving prior pause state, then unconditionally calls `await coordinator.setPaused(false)` and `startTrackingIfReady()` (`lines 321-322`), failing open and restarting the camera after `Esc` or error.
- **Fix Guidance:** Capture `let wasPaused = await coordinator.paused()` before line 279 and restore `await coordinator.setPaused(wasPaused)` across exit paths (optionally keeping `wasPaused` on cancel/error and only unpausing on `.success` if intended, or restoring `wasPaused` uniformly).
- **Acceptance Test Criterion:** Code verification in `AppController.swift` ensuring `wasPaused == true` remains paused after `.failure(.cancelled)` and `.failure(_)`.

#### `TRG-27` (`P3` | Source: `CR-23`) — `WindowHitTester` snap ignores nearer ineligible windows
- **Where:** `Sources/iFocusCore/Targeting/WindowHitTester.swift:31-37`.
- **Verified Defect:** Snap searches only `isEligible(window, config: config)`, so a gaze point in a gap 5 pt from Safari and 60 pt from a terminal snaps to the terminal instead of returning `.none`.
- **Fix Guidance:** Only snap to the nearest eligible window when no ineligible non-trivial window (`layer == 0 && bounds.width >= 120 && bounds.height >= 80`, or any `layer == 0` non-chrome window) is strictly closer to `point`.
- **Acceptance Test Criterion:** `HitTestTests` (`T17`) extended with a gap point closer to Safari than to Terminal asserting `.none`, while existing `T17` assertions stay green.

#### `TRG-28` (`P3` | Source: `CR-24b`) — `HUDController.flash` resets `alphaValue` outside zero-duration animation group
- **Where:** `Sources/iFocusMac/UI/HUDController.swift:73-95`.
- **Verified Defect:** Setting `panel.alphaValue = 1.0` (`line 82`) directly while an earlier `panel.animator().alphaValue = 0.0` CoreAnimation transaction (`lines 85-88`) is still running can cause the new flash to be cut short.
- **Fix Guidance:** Reset `panel.alphaValue = 1.0` inside `NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0; panel.alphaValue = 1.0 }` before starting the `0.4 s` fade-out group.
- **Acceptance Test Criterion:** Code verification in `HUDController.swift` + warning-free Swift 6 build.

---

## (c) Rejected False Positives & Deferred v2 Roadmap Items

### Rejected False Positives (`0`)
None — all 32 raw observations from `code-reviewer` and `sec-reviewer` were corroborated by exact `file:line` inspection in the codebase.

### Deferred to v2 (`2` — for `reporter`'s v2 Roadmap)
- **`DEF-01` (`CR-11`, `DEFERRED_V2`):** *Post-typing-pause re-dwell option for copy-from-reference workflows* (`Sources/iFocusCore/Engine/FocusDecisionEngine.swift:138-155`). **Rationale:** Current behaviour (`switch immediately once typingLockSeconds elapses after typing pauses`) matches the ratified Round 1 behaviour contract (`docs/plans/final-plan-r1.md` §2, §4.7) and acceptance tests `T27` and `T37`. Adding a configurable `freshDwellAfterTypingLock: Bool` / persistent mismatch border is a v2 feature enhancement, not a v1 defect.
- **`DEF-02` (`CR-24a`, `DEFERRED_V2`):** *Public-mode native-tab disambiguation when `AXWindows` includes hidden native tabs sharing identical frames* (`Sources/iFocusCore/Targeting/AXWindowMatcher.swift:23-26`). **Rationale:** Returning `.ambiguous(index: lowest AX index, count)` in public mode implements `docs/plans/final-plan-r1.md` §4.8 and test `T30`. Native-tab inspection (`AXTabs` / tab-bar filtering) belongs to the v2 terminal pane/tab bridge roadmap.

---

## (d) Explicit Loop Recommendation

**`RESTART_LOOP`**

**Basis:** `6` validated `P1` blockers/high-risk defects (`TRG-01`..`TRG-06`, covering camera start/stop race, calibration overlay trap, 6 s per-window AX stall, lock-screen camera reactivation, `layer > 0` dialog occlusion blindness, and `hardBlocklist` bypass when `requireAllowedSource == false`) plus `12` validated `P2` engineering/security hardenings (`TRG-07`..`TRG-18`). Round 2 remediation planning (`planner-a` + `planner-b` -> `arbiter` -> `builder`) is required before final report sign-off.
