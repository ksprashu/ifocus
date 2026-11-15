# iFocus Design & Architecture

## 1. Purpose and Non-Goals

iFocus moves keyboard focus to whichever desktop window the user is looking at on macOS (14+), using only the built-in or external webcam and macOS Accessibility (`AXUIElement`) APIs.

**Non-goals:**

- No cursor warping, synthetic keystrokes/clicks, `CGEventTap`, or global `NSEvent` monitors (invariant `I1`).
- No Screen Recording or Input Monitoring permissions (TCC grants are **Camera** and **Accessibility** only).
- No reading of window titles (`kCGWindowName` or `kAXTitleAttribute` forbidden by `I1`).
- No disk persistence of camera frames, crops, or gaze traces, and no network I/O (`I9`).
- No sub-window terminal pane/tab IPC in v1 (`DEF-02` deferred to v2).

## 2. Module Map

Defined in [Package.swift](Package.swift#L11-L16) with zero third-party dependencies:

| Target | Role | Purity / Constraints |
|---|---|---|
| `iFocusCore` | Geometry, filtering, calibration solver, 9-rule window classifier, 14-veto safety policy, decision engine, AX matcher, focus ladder, coordinator, simulation rig & runner | Imports `Foundation` and `CoreGraphics` only (`I3`); virtual-clock/sleeper injectable |
| `iFocusMac` | `AVCaptureSession` + Vision landmark extractor, `CGDisplayBounds` topology, `CGWindowList` catalog, `AXUIElement` actuator + `dlopen` `_AXUIElementGetWindow`, AppKit calibration overlay, HUD flash, Carbon hotkey, status menu, CLI `--doctor` & app lifecycle | Native macOS adapters behind `iFocusCore` protocols |
| `iFocusApp` | `@main` entry point dispatching `--run`, `--calibrate`, `--doctor`, `--simulate`, `--version`, `--help` | Synchronous `main()` (`Sources/iFocusApp/IFocusCLI.swift#L8`) |

## 3. Coordinate Spaces

macOS splits screen geometry between Quartz top-left coordinates (`CGDisplayBounds`, `CGWindowBounds`) and AppKit bottom-left coordinates (`NSScreen.frame`):

- **Canonical internal frame:** Quartz global points with origin at the top-left of the primary display (`mainDisplayBounds.origin == (0, 0)`).
- **Single-height conversion:** [CoordinateSpace.swift](Sources/iFocusCore/Geometry/CoordinateSpace.swift#L3-L18) converts between Quartz and AppKit exclusively via `primaryHeight` (the height of the main display, not the target screen), keeping vertically asymmetric multi-display arrangements (portrait side monitor, built-in laptop panel below) aligned.
- **Physical grounding:** [CGDisplayTopologyService.swift](Sources/iFocusMac/Display/CGDisplayTopologyService.swift) records `CGDisplayScreenSize` (mm), logical bounds, `isMain`, `isBuiltin`, and persistent `CFUUID` string (`CGDisplayCreateUUIDFromDisplayID`) so calibration survives display renumbering and reconnects.

## 4. Gaze Features & One-Euro Filtering

1. **Frame decimation (`FrameDecimator`):** [FrameDecimator.swift](Sources/iFocusCore/Filter/FrameDecimator.swift#L3-L32) enforces `cameraFPS` (default `20` Hz) by phase-locked scheduling (resets phase cleanly across `> 0.25 s` gaps), independent of hardware `activeVideoMinFrameDuration` range support.
2. **In-memory Vision landmarks (`FrameProcessor`):** [FrameProcessor.swift](Sources/iFocusMac/Gaze/FrameProcessor.swift) runs `VNDetectFaceRectanglesRequest` and `VNDetectFaceLandmarksRequest` (revision 3) on the largest detected face, recording total `faceCount`, head `yaw`/`pitch`/`roll`, and pupil + eye-contour points without retaining pixel buffers.
3. **Contour de-roll (`EyeGeometry`):** [EyeGeometry.swift](Sources/iFocusCore/Filter/EyeGeometry.swift#L4-L43) normalises the inter-ocular eye-contour axis (or single-eye major axis fallback) to point toward `+x` and rotates both contour and pupil points into head-level coordinates, preventing head roll (`+/- 30°`) from registering as gaze shift.
4. **Smoothing & blink hold (`GazeFeaturePipeline` & `OneEuroFilter`):** Four [OneEuroFilter.swift](Sources/iFocusCore/Filter/OneEuroFilter.swift#L3) instances smooth head pose (`minCutoff = 1.2, beta = 4.0`) and pupil offset (`minCutoff = 0.8, beta = 5.0`), suppressing micro-jitter while preserving saccade responsiveness. Through short blinks (`<= eyeHoldSeconds`, `0.30 s`), [GazeFeaturePipeline.swift](Sources/iFocusCore/Filter/GazeFeaturePipeline.swift#L3) holds the last valid eye offset before gracefully falling back to the head-only model.

## 5. Per-Display Ridge Calibration

- **Wizard (`CalibrationSession` & `CalibrationOverlay`):** Captures a two-pass per-display plan (9 targets with natural head+eye movement followed by 5 eyes-only targets) across every connected display ([CalibrationSession.swift](Sources/iFocusCore/Calibration/CalibrationSession.swift#L45)).
- **Solver (`CalibrationSolver` & `RidgeSolver`):** Fits independent full (`[yaw, pitch, eyeX, eyeY]`) and head-only (`[yaw, pitch]`) ridge regressions (`lambda = 0.05`) per display UUID ([CalibrationSolver.swift](Sources/iFocusCore/Calibration/CalibrationSolver.swift#L62)), rejects outliers via MAD, computes leave-one-target-out cross-validation RMS (refused above `0.20`), checks convex hull area (`>= 0.05`) and head-motion range (`>= 0.02 rad` unless eyes-only), and embeds camera/display signatures ([CalibrationProfile.swift](Sources/iFocusCore/Calibration/CalibrationProfile.swift#L105)).
- **Display selection (`CalibrationMapper`):** Projects incoming conditioned features onto every calibrated display's normalised `(u, v)` plane, prefers an enclosing calibrated display with hysteresis stickiness to the previous display, or selects the nearest panel in millimetres while rejecting samples beyond `offscreenMarginMM` (`60 mm`) / `offscreenMarginBottomMM` (`20 mm`) ([CalibrationMapper.swift](Sources/iFocusCore/Calibration/CalibrationMapper.swift)).

## 6. Window Census & 9-Rule Classifier

[CGWindowCatalogService.swift](Sources/iFocusMac/Windows/CGWindowCatalogService.swift) captures `kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements` per snapshot (resolving bundle IDs fresh per call with zero persistent PID cache), reads `kCGWindowOwnerName` when `NSRunningApplication` omits a bundle identifier (`WindowClassifier.canonicalBundleID`), and feeds each entry into the pure 9-rule [WindowClassifier.swift](Sources/iFocusCore/Targeting/WindowClassifier.swift#L22-L90):

1. Own PID, `alpha <= 0.01`, empty bounds, or `layer < 0` -> `.ignored`.
2. Canonical bundle ID in `Config.securityPromptBundleIDs` and bounds `>= 40x40 pt` -> `.securityPrompt`.
3. `com.apple.loginwindow` with `layer >= 1000` and `>= 40x40 pt` -> `.securityPrompt`.
4. `layer == 0` -> `.normal`.
5. `layer >= 1000` -> `.ignored` (e.g., Window Server shield `2147483646`).
6. Bundle ID in `Config.chromeBundleIDs` (only non-nil IDs; nil IDs fail closed to occlusion checks) -> `.ignored`.
7. Width `< 40 pt` or height `< 40 pt` (menu bar strip / status bar items) -> `.ignored`.
8. Covers `>= 80%` of any active display's area (skipped when `displayBounds` is empty) -> `.ignored`.
9. Otherwise -> `.occluder` (layer > 0 dialogs, alerts, Spotlight panel).

[WindowHitTester.swift](Sources/iFocusCore/Targeting/WindowHitTester.swift#L35) walks retained windows front-to-back in CG z-order: the frontmost containing window determines `.window(w)` (if eligible) or `.blocked` (ineligible front window or layer > 0 occluder). When gaze lands on uncovered empty space within `snapRadiusPoints` (`80 pt`), hit-testing snaps to the closest eligible window only if no strictly closer large (`>= 120x80`) or `layer > 0` ineligible window sits nearer.

## 7. Eligibility & `focusScope`

[Config.swift](Sources/iFocusCore/Model/Config.swift#L254-L264) evaluates eligibility via one shared predicate `isBundleAllowed(_:)` used by `WindowHitTester.isEligible`, MRU display fallback, and `DefaultSafetyGuardPolicy`:

1. `nil` or empty bundle IDs are rejected (fail closed).
2. Unconditional hard blocklist (`Config.hardBlocklist` covering auth agents, Lock/ScreenSaver, System Settings, Spotlight, system chrome, password managers `1Password`, `Passwords`, `Keychain Access`, and `dev.ifocus.app`) and `Config.hardBlockPrefixes` (`com.1password.`, `com.agilebits.onepassword`, `com.bitwarden.`, `com.apple.Passwords`) are always denied. `AppController` and `Doctor` also append `Bundle.main.bundleIdentifier` into `excludedBundleIDs` at startup.
3. User-configured `excludedBundleIDs` (up to 64 validated IDs) are denied in both scopes.
4. `focusScope`:
   - `.allApps` (default): any other identified layer-0 window `>= 120x80 pt` is eligible.
   - `.allowlist` (also the safe fallback when an unrecognised `focusScope` string appears in JSON): restricted to `allowedBundleIDs`.

## 8. Decision Engine (`FocusDecisionEngine`)

[FocusDecisionEngine.swift](Sources/iFocusCore/Engine/FocusDecisionEngine.swift#L4) implements quiet-then-dwell gating with sticky hysteresis and challenger anti-starvation:

- **Sticky margin (`48 pt`):** Same-display neighbour targets are suppressed while gaze stays inside the focused window inflated by `stickyMarginPoints`, unless a front overlapping window (`zIndex < focused.zIndex`) directly contains the gaze point.
- **Challenger anti-starvation:** Occasional single-frame glitches (`<= candidateDropoutSeconds = 0.12 s`) onto a neighbour create a `challenger` without resetting `pending`; commit proceeds once no live challenger exists, whereas steady transition promotes `challenger.enteredAt` cleanly and 50/50 boundary oscillation commits to neither.
- **Quiet period + fresh dwell:** Because `.typing` and `.pointerActive` both carry `.clear` disposition, any keyboard, modifier-held, pointer-move, click, drag, scroll, or mouse-button-down input clears both `pending` and `challenger` (`dwellProgress = 0`). Dwell (`1.2 s` cross-display, `1.5 s` same-display) starts from zero only after the full quiet interval (`2.5 s` key/click, `2.0 s` pointer move) expires.
- **Pre-commit confirmation:** Before executing any AX mutation, [FocusCoordinator.swift](Sources/iFocusCore/Engine/FocusCoordinator.swift#L425-L450) takes a fresh `WindowSnapshot`, `DisplayTopology`, and `InputActivity`, and verifies `FocusPipeline.confirm(...)` succeeds on the exact `target.windowID` and `target.pid`.

## 9. Safety Policy (14 Ordered Vetoes)

Evaluated in fixed order by [SafetyPolicy.swift](Sources/iFocusCore/Engine/SafetyPolicy.swift#L6-L78), using dispositions from [FocusTypes.swift](Sources/iFocusCore/Model/FocusTypes.swift#L65-L76):

| # | Veto | Condition | Disposition |
|---|---|---|---|
| 1 | `.paused` | User toggled pause (menu or hotkey) | `.clear` |
| 2 | `.sessionInactive` | `CGSessionCopyCurrentDictionary()` locked/off-console or sleep active | `.clear` |
| 3 | `.secureInput` | `respectSecureInput && IsSecureEventInputEnabled()` | `.clear` |
| 4 | `.sourceNotAllowed` | Global `securityPromptVisible` (Prompt on any display) | `.clear` |
| 5 | `.uncalibrated` | No valid display calibration (`calibration == nil` / uncalibrated display) | `.clear` |
| 6 | `.noGaze` | Off-screen or no face | `.dropout` |
| 7 | `.staleGaze` | `now - gazePoint.timestamp > staleSampleSeconds` (`0.30 s`) | `.dropout` |
| 8 | `.lowConfidence` | `confidence < minConfidence` (`0.50`) | `.dropout` |
| 9 | `.multipleFaces` | `faceCount > 1` | `.dropout` |
| 10 | `.lookingDown` | `headPitch > pitchDownLimit + lookDownMarginRadians` | `.dropout` |
| 11 | `.sourceNotAllowed` | Frontmost app `isHardBlocked` (unconditional) or excluded / disallowed (`requireAllowedSource`) | `.clear` |
| 12 | `.pointerActive` | Mouse button down, move `< 2.0 s`, or click/drag/scroll `< 2.5 s` | `.clear` |
| 13 | `.failureBackoff` | Within `failureBackoffSeconds` (`2.0 s`) of previous failed ladder | `.clear` |
| 14 | `.typing` | Shift/Control/Option/Command held OR key-down/up/flags-changed `< 2.5 s` | `.clear` |
| 15 | `.cooldown` | Within `switchCooldownSeconds` (`0.60 s`) of last `.switched` | `.hold` |

*(Checks 4 and 11 share the `.sourceNotAllowed` case so `SafetyVeto` maintains 14 exhaustive cases; check 4 populates `CoordinatorStatus.detail` with `"System prompt on screen: <bundleID>"`.)*

## 10. Focus Ladder (`LadderFocusSwitcher` & `AXActuator`)

[LadderFocusSwitcher.swift](Sources/iFocusCore/Engine/LadderFocusSwitcher.swift#L26) short-circuits to `.alreadyFocused` only when **both** `snapshot.frontmostPID == target.pid` and `snapshot.focusedWindowID == target.windowID`:

- **Same-PID rungs:** `rungA: [.raiseAndMakeMain]` -> `rungB: [.raiseAndMakeMain, .setAppFrontmost]` -> `rungC: [.raiseAndMakeMain, .activateApp]` (`3` verification polls 50 ms apart).
- **Cross-PID rungs:** Skips `rungA`; runs `rungB: [.raiseAndMakeMain, .setAppFrontmost, .raiseAndMakeMain]` -> `rungC: [.raiseAndMakeMain, .activateApp, .raiseAndMakeMain]` (`8` verification polls 50 ms apart, accommodating asynchronous macOS app activation).
- **Candidate re-match:** If any step returns `.staleCandidate`, the ladder re-enumerates `actuator.windows(of: target.pid)`, re-matches by `CGWindowID` (or public geometric fallback), and retries that step once.
- **Verification & Rollback:** A rung is `.switched` only when `snapshot.frontmostPID == target.pid && snapshot.focusedWindowID == target.windowID && keyWindowCheck != .differs`. Unverified, timed-out (`1.0 s`), or `.staleCandidate` terminations trigger a bounded (`0.35 s`) rollback to the initial window (skipped on timeout when target shares the initial PID).
- **Native AX bounds (`AXActuator`):** [AXActuator.swift](Sources/iFocusMac/Focus/AXActuator.swift) sets a `0.25 s` `AXUIElementSetMessagingTimeout` on app, window, and focused-window elements, aborts on the first `.cannotComplete` or `0.5 s` enumeration wall budget, and resolves `_AXUIElementGetWindow` safely inside [AXWindowID.swift](Sources/iFocusMac/Focus/AXWindowID.swift).

## 11. Concurrency Model

- **Coordinator generation fence:** [FocusCoordinator.swift](Sources/iFocusCore/Engine/FocusCoordinator.swift#L228-L286) is an `actor` using monotonic `generation` tokens and chained `stopTask` cleanup so `start()` during an in-flight `stop()` never leaks a live estimator stream or creates overlapping capture streams. Logs are capped in an `O(1)` 4096-entry `RingBuffer`, statuses are deduplicated, and permission checks use a `1.0 s` TTL invalidated on explicit user actions.
- **Watchdog & camera lifecycle:** [WatchedStream.swift](Sources/iFocusCore/Engine/WatchedStream.swift#L8) wraps calibration frame streams with a `5.0 s` stall watchdog; [CameraSession.swift](Sources/iFocusMac/Gaze/CameraSession.swift) confines `AVCaptureSession` mutations to a serial queue and tears down immediately on `runtimeError`, `wasInterrupted`, `wasDisconnected`, or session lock.
- **Session gating:** [SystemSessionStateProvider.swift](Sources/iFocusMac/Input/SystemSessionStateProvider.swift) computes activity purely from `CGSessionCopyCurrentDictionary()` + workspace sleep flags (never trusting unlock notifications directly) with a 5 s inactive retry heartbeat; [FocusCoordinator.swift](Sources/iFocusCore/Engine/FocusCoordinator.swift#L290-L298) also refuses to call `gazeEstimator.start()` while the session is inactive.

## 12. Threat Model

- **Assets protected:** Keystroke destination integrity (preventing wrong-window Return/typing), password/auth dialogs & password-manager contents, lock-screen camera privacy, user config/calibration integrity.
- **Trust boundaries:** Untrusted on-screen windows (spoofed overlays, missing bundle IDs, hung AX servers), `~/Library/Application Support/iFocus/` filesystem entries, distributed session notifications, temporary build directories.
- **Mitigated threats (Round 1 & 2 security closures + Wave 2 controls):**
  - Lock-screen camera persistence (`CGSessionCopyCurrentDictionary` fail-closed gating + calibration cancel).
  - Unauthenticated overlay / prompt clickjacking (9-rule classifier + global prompt veto + `kCGWindowOwnerName` fallback + `CoreAuthUI` alias).
  - Blocklist bypass when `requireAllowedSource = false` (unconditional `isHardBlocked` + password-manager blocklist/prefixes + Spotlight panel occlusion).
  - Symlink/TOCTOU config tampering (`open(O_DIRECTORY | O_NOFOLLOW)` descriptor pinning + `openat`/`renameat` + `0700`/`0600` strict read validation) and `/tmp` build dir hijacking (`prepare_secure_dir` per-UID `0700` checks).
  - Coordinator start/stop/unbounded-log availability & PID-reuse stale caches (`generation` fence, `RingBuffer(4096)`, per-snapshot PID lookup).
- **Residual risks:** (1) Look-then-type within ~1.2 s (idle) keeps focus on the old window by design; (2) quarter-tiled or sub-pane layouts remain window-level in v1; (3) `.app` ad-hoc signatures rotate CDHashes on rebuild unless `IFOCUS_SIGN_IDENTITY` is configured; (4) Dock / notification banners at layer > 0 pass through (`DEF-04`).

## 13. Testing Strategy

All core logic runs deterministically under Swift Testing (`Tests/iFocusCoreTests/`):

- **Virtual time & deterministic physical simulation:** `VirtualClock`, `VirtualSleeper`, `Rig` (`deskThree`, `dualExternal`, `mixedApps`), and `SyntheticUser` drive [ScenarioRunner.swift](Sources/iFocusCore/Simulation/ScenarioRunner.swift) through the real `FocusPipeline` and `FocusCoordinator` + `LadderFocusSwitcher`.
- **93 Acceptance & Regression Tests (`T01`–`T93` across 17 suites):**
  - `T01`–`T54`: Core geometry, One-Euro filter, calibration solver/mapper, hit-testing, 14 safety vetoes, dwell/challenger/hysteresis engine, `AXWindowMatcher`, `LadderFocusSwitcher`, `SecureFileStore`, scenarios.
  - `T55`–`T78`: Lifecycle race & `WatchedStream`, AX timeouts & rollback, session signals, 9-rule classifier & `WindowHitTester` snap/occlusion, `FrameDecimator`, `EyeGeometry`, `SecureFileStore` hardening, `runWithLadder`.
  - `T79`–`T93`: Wave 2 `Config` defaults/`focusScope`/`excludedBundleIDs`, `2.5 s` quiet + `1.2 s`/`1.5 s` fresh dwell across all 5 input classes, dropout-typing clear, `allApps` eligibility & password-manager/Spotlight/`CoreAuthUI` defenses, cross-PID Ghostty/Spotify/Chrome multi-window ladders, `activationLatencySeconds` 8-poll verification, `RC1` frontmost+window check, and `TRG2-02` `.staleCandidate` rollback.
