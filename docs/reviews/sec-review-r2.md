# Round 2 Security Review & Deep Regression Audit (`sec-review-r2`)

- **Target Commit:** `ddc35505ba8e1402cce15f80f2448d1e87ff23f7` (`main`, parent `fb078be3ba8e161701e8ca7784259caa241eaf1e`)
- **Prior Triage Baseline:** `docs/reviews/triage-r1.md` (`TRG-01`–`TRG-28`; `SEC-001`–`SEC-008`)
- **JSON Findings Contract:** `docs/reviews/sec-review-r2.json` (`findings.py validate` & `findings.py gate` both exit `0`)
- **Gate Verdict:** **PASS (`0` open blocking findings across `P0`/`P1`/`P2`/`P3`; `8/8` Round 1 security findings verified `fixed` with zero regressions)**

---

## 1. Automated Gate & Scanner Verification

| Gate / Tool | Result | Evidence |
| :--- | :--- | :--- |
| **Isolated Test Suite (`sbx.sh test`)** | **PASS (`0` warnings)** | `IFOCUS_SBX_OUT="/tmp/ifocus-sr-$(id -u)" ./scripts/sbx.sh test` -> **78/78 tests in 17 suites passed** (`0.808 s`). |
| **Static Invariants (`check-invariants.sh`)** | **PASS** | `I1`–`I7` passed (including tightened `I4` confining `nonisolated(unsafe)` to `LockedBox` in `SimServices.swift:6`). |
| **Script Hardening (`check-scripts.sh`)** | **PASS** | Verified `scripts/sbx.sh` and `scripts/bundle-app.sh` exit `1` without writing artefacts when `IFOCUS_SBX_OUT` is a symlink. |
| **Secrets & Misconfig (`gitleaks` 8.30.1, `trivy` 0.76.1)** | **CLEAN** | `0` secret or misconfiguration leads across git history (`run_scanners.py --audit`) and working tree (`gitleaks dir --redact`, `trivy fs`). |
| **Supply Chain & Entitlements** | **CLEAN** | Zero external dependencies in `Package.swift`; hardened runtime (`--options runtime`) with sole entitlement `com.apple.security.device.camera`. |
| **Semgrep (`not_inspected`)** | **ERROR (`exit 2`)** | Blocked by workspace sandbox reading `~/.semgrep/settings.yml` (preserved in `not_inspected`; full manual line-by-line review completed across all 55 changed/new files). |

---

## 2. Closure Audit of Round 1 Security & Safety Findings

Every security finding from `sec-review-r1` and every security-adjacent item in `triage-r1` was audited against commit `ddc3550`:

| R1 ID | Triage ID | Sev | Status | Verification & Regression Proof |
| :--- | :--- | :---: | :---: | :--- |
| **SEC-001** | `TRG-04` | `P1` | **FIXED** | `SystemSessionStateProvider.swift:26-195` queries `CGSessionCopyCurrentDictionary()` on `init`, on workspace/distributed notifications (treating `DistributedNotificationCenter` posts purely as re-query triggers), and on `0.25 s`-TTL `isSessionActive()` checks, failing closed (`screenLocked: true`) if `CGSessionCopyCurrentDictionary()` is `nil`. `AppController.runCalibrateCommand()` (`AppController.swift:42-63`), `AppController.start()` (`line 244`), and `FocusCoordinator.supervise` (`FocusCoordinator.swift:289-298`) refuse/cancel camera capture while locked or asleep. Proven by `T59` and `T78`. |
| **SEC-002** | `TRG-05` | `P1` | **FIXED** | `CGWindowCatalogService.swift:62-95` + `WindowClassifier.swift:11-90` retain visible `layer > 0` dialogs/panels (`< 80%` display area, `>= 40x40 pt`) as `.occluder` entries while requiring `window.layer == 0` in `WindowHitTester.isEligible`. Security prompts (`SecurityAgent`, `coreautha`/`com.apple.LocalAuthentication.UIAgent`, `UserNotificationCenter`, `CoreServicesUIAgent`, and `loginwindow` at `layer >= 1000`) resolve by bundle ID or `kCGWindowOwnerName` fallback before high-layer/area filters and trigger a global `.sourceNotAllowed` veto in both `step()` and `confirm()`. Proven by `T60`, `T61`, `T62`, `T77`, and live locked-machine `G7` `--doctor` census. |
| **SEC-003** | `TRG-06` | `P1` | **FIXED** | `SafetyPolicy.swift:47-49` enforces `Config.hardBlocklist` unconditionally before checking `requireAllowedSource`, and `Config.swift:16-31` adds `com.apple.LocalAuthentication.UIAgent`, `com.apple.UserNotificationCenter`, `com.apple.ScreenSharing`, and `com.apple.Settings`. Proven by `T63`. |
| **SEC-004** | `TRG-17` | `P2` | **FIXED** | `scripts/sbx.sh:5-22` and `scripts/bundle-app.sh:5-48` default scratch/cache paths to UID-scoped directories (`-$(id -u)`) and validate every directory with `prepare_secure_dir()` (stripping trailing `/` before `-L` symlink rejection, `mkdir -p -m 0700`, `-O` UID ownership check, and `chmod 0700`). Proven by `G6` (`scripts/check-scripts.sh`). |
| **SEC-005** | `TRG-12` | `P2` | **FIXED** | Persistent `bundleIDCache` deleted (`0` occurrences in `Sources/`); `CGWindowCatalogService.swift:36` uses a per-snapshot local `[Int32: String?]` dictionary, eliminating PID-wraparound inheritance and unbounded growth. |
| **SEC-006** | `TRG-18` | `P2` | **FIXED** | `SecureFileStore.swift:57-194, 226-256` opens `dirFD` with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` (handling Darwin's `ENOTDIR`-on-symlink behaviour), rejects `(dirStat.st_mode & 0o077) != 0` on `read()`, repairs modes via `fchmod(dirFD, ...)` on `write()`, and uses `openat`/`renameat`/`unlinkat` relative to `dirFD`. Proven by `T34` and `T71`. |
| **SEC-007** | `TRG-07` | `P2` | **FIXED** | `FocusCoordinator.swift:45-80` replaces the unbounded array with a fixed-capacity `RingBuffer` (`4096` entries). Proven by `T64` while keeping `T38` green. |
| **SEC-008** | `TRG-26` | `P3` | **FIXED** | `AppController.swift:319-372` records `wasPaused` on entry to `runInteractiveCalibration()` and restores `setPaused(wasPaused)` across all exit paths (permission denied, inactive session, cancel, error, and success). |
| *(CR-01)* | `TRG-01` | `P1` | **FIXED** | Generation-fenced `FocusCoordinator` supervision (`FocusCoordinator.swift:228-376`) eliminates the camera-leak race on rapid `start(); stop()` and overlapping `stop(); start()`. Proven by `T55` and `T56`. |
| *(CR-03)* | `TRG-02` | `P1` | **FIXED** | `CalibrationOverlay` (`CalibrationOverlay.swift:137-299`) tears down `.screenSaver` windows immediately on `Esc`, clickable `"Cancel (Esc)"` `NSButton`, session lock, camera error/interruption (`CameraSession.swift:203-257`), or `5 s` `WatchedStream` silence stall. Proven by `T57` and `T70`. |
| *(CR-04)* | `TRG-03` | `P1` | **FIXED** | `AXActuator.swift:24, 133, 153` sets `0.25 s` messaging timeouts on app, window, and focused-window `AXUIElement`s with `.cannotComplete` circuit-breaking and a `1.0 s` `LadderFocusSwitcher` deadline + `0.35 s` bounded rollback (`TRG-09`). Proven by `T58`, `T66`, `T68`, and `T72`. |
| *(CR-05)* | `TRG-08` | `P2` | **FIXED** | `AXWindowMatcher.swift:13` restricts geometric/approximate fallback to `windowID == nil` candidates, preventing wrong-window actuation when known `CGWindowID`s differ. Proven by `T65`. |

---

## 3. STRIDE & New-Code Differential Audit (`ddc3550`)

All newly introduced Round 2 modules were audited for secondary vulnerabilities:

- **`WindowClassifier.swift` & `CGWindowCatalogService.swift`:** `kCGWindowOwnerName` is mapped strictly through a closed 5-entry dictionary (`Config.promptOwnerNames`) to trigger defensive vetoes (`securityPrompt`), never to grant `allowedBundleIDs` eligibility (`Config.hardBlocklist` blocks all 5 canonical IDs). Window titles (`kCGWindowName` / `kAXTitleAttribute`) remain completely unread across the codebase.
- **`WatchedStream.swift`:** Instantiated exclusively in `CalibrationOverlay.run` over a `.bufferingNewest(1)` 5–30 Hz camera stream with a 5 s stall timeout and deterministic task cancellation in `onTermination`, `cancel()`, and `defer`.
- **`SystemSessionStateProvider.swift`:** `OSAllocatedUnfairLock` protects value-type `InternalState` without re-entrancy (`CGSessionCopyCurrentDictionary()` runs outside the lock); `stopObserving()` cancels `heartbeatTask` and removes all notification tokens cleanly.
- **`IFocusCLI.swift` & `Doctor.swift`:** Synchronous `@main` entrypoint validates CLI flags strictly (exiting `64` on unexpected options), spawns zero subprocesses, and prints only window IDs, PIDs, bundle/process owner names, layers, and bounds.

**Conclusion:** Zero open `P0`–`P3` security findings remain. Round 2 is clear for release sign-off from a security perspective.
