# Round 1 Security Review & Deep Scan (`sec-review-r1`)

- **Target Commit:** `fb078be3ba8e161701e8ca7784259caa241eaf1e` (`main`)
- **Scope:** Full repository (`Package.swift`, `Resources/*`, `scripts/*.sh`, `Sources/iFocusCore/**`, `Sources/iFocusMac/**`, `Sources/iFocusApp/*`, `Tests/iFocusCoreTests/*`)
- **JSON Findings Contract:** `docs/reviews/sec-review-r1.json` (validated via `findings.py validate`)
- **Gate Verdict:** **HOLD (`8` open blocking findings: `3 P1`, `4 P2`, `1 P3`; `0 P0`)**

---

## 1. STRIDE Threat Model & Trust Boundaries

- **Assets:** Live 720p webcam frames (`CMSampleBuffer` / `CVPixelBuffer`), user keyboard activity & password entry timing (`SecureEventInput`), macOS Accessibility window focus control (`AXUIElement`), persistent security/calibration files (`~/Library/Application Support/iFocus/{config,calibration}.json`), and developer code-signing execution context (`scripts/*.sh`).
- **Entry Points:** Camera frame callbacks (`AVCaptureVideoDataOutput`), WindowServer display/window lists (`CGWindowListCopyWindowInfo`), cross-process `AXUIElement` attributes, `NSWorkspace` and `DistributedNotificationCenter` session notifications, local JSON files in `Application Support/iFocus`, CLI flags (`IFocusCLI`), and environment variables (`IFOCUS_SBX_OUT`, `IFOCUS_SBX_OPT`, `IFOCUS_SIGN_IDENTITY`).
- **Trust Boundaries:**
  1. *Locked Console & Unauthenticated Session Bus -> TCC Camera / Accessibility Agent* (`SystemSessionStateProvider` -> `AppController` / `VisionGazeEstimator` / `AXActuator`).
  2. *Foreground Modal / Security Prompts (`layer > 0`, `SecurityAgent`, `CoreAuthUI`, `UserNotificationCenter`) -> Background Terminal Activation* (`CGWindowCatalogService` + `WindowHitTester` + `DefaultSafetyGuardPolicy`).
  3. *Shared Multi-User `/tmp` & Local Filesystem -> Developer Shell / Code Signing & Runtime Config* (`scripts/sbx.sh`, `scripts/bundle-app.sh`, `SecureFileStore`).
  4. *Continuous 20-30 Hz Sensor Loop -> Long-Running Menu-Bar Daemon Heap* (`FocusCoordinator`, `CGWindowCatalogService`).
- **STRIDE Summary:**
  - *Spoofing:* Unauthenticated `DistributedNotificationCenter` session unlock/lock broadcasts (**SEC-001**); stale PID->bundleID cache after macOS PID wraparound (**SEC-005**).
  - *Tampering:* Shared predictable `/tmp/ifocus-sbx` build/test/sign directories (**SEC-004**); group/world-writable config directory accepted on `SecureFileStore.read` + pathname TOCTOU (**SEC-006**).
  - *Information Disclosure:* Webcam reactivation behind the macOS lock screen on display wake (**SEC-001**); silent camera reactivation after cancelling calibration from a paused state (**SEC-008**); credential keystrokes diverted from system auth prompts into plaintext terminal shells (**SEC-002**, **SEC-003**).
  - *Denial of Service:* Spoofed `com.apple.screenIsLocked` broadcast disabling tracking (**SEC-001**); unbounded 20-30 Hz `decisionLog` growth in `FocusCoordinator` (**SEC-007**).
  - *Elevation of Privilege:* Arbitrary code execution / malicious Mach-O signing via `/tmp/ifocus-sbx` hijack (**SEC-004**); UI-redressing focus hijack across `layer > 0` dialogs (**SEC-002**).
- **Out of Scope:** Network/TLS/HTTP surfaces (verified zero network sockets, URL fetches, or third-party dependencies in `Package.swift`).

---

## 2. Scanner, Invariant & Clean-Surface Verification

| Check / Surface | Result | Verification Evidence |
| :--- | :--- | :--- |
| **Isolated Test Suite (`sbx.sh test`)** | **PASS** | `IFOCUS_SBX_OUT=/tmp/ifocus-sr ./scripts/sbx.sh test` -> **54/54 tests in 17 suites passed**. |
| **Static Invariants (`check-invariants.sh`)** | **PASS** | `I1`-`I7` passed (zero `CGEventTap`, `addGlobalMonitorForEvents`, `CGWarpMouseCursorPosition`, `kCGWindowName`, `kAXTitleAttribute`, `try!`, `fatalError`). |
| **Secrets Scan (`gitleaks` 8.30.1 + `trivy` 0.76.1)** | **CLEAN** | `0` secret leads across git history (`run_scanners.py --audit`) and working tree (`gitleaks dir --redact`, `trivy fs --scanners secret,misconfig`). |
| **Supply Chain (`Package.swift`)** | **CLEAN** | Zero external SwiftPM, npm, Python, or binary dependencies. |
| **Semgrep (`not_inspected`)** | **ERROR (exit 2)** | Blocked by sandbox accessing `~/.semgrep/settings.yml` (recorded in `not_inspected`; manual full-tree Swift/shell review completed across all 44 production files). |
| **Keystroke / Event Tap Privacy** | **CLEAN** | `SystemInputActivityProvider.swift:12-35` queries only `CGEventSource.secondsSinceLastEventType(.combinedSessionState, ...)` and `IsSecureEventInputEnabled()`; `HotKeyController.swift:48` uses Carbon `RegisterEventHotKey` for a single shortcut; zero keycodes or characters are ever read, buffered, or logged. |
| **Camera Frame Volatility & CF Memory** | **CLEAN** | `CameraSession.swift:156` sets `alwaysDiscardsLateVideoFrames = true`; `VisionGazeEstimator.swift:48,61` bounds `AsyncStream` to `.bufferingNewest(1)` scalar `GazeEvent` values; `FrameProcessor.swift:44-55` never retains, logs, or serialises `CMSampleBuffer` or `CVPixelBuffer`; `AXUIElementCopyAttributeValue` (`CF_RETURNS_RETAINED`) and `CGDisplayCreateUUIDFromDisplayID()?.takeRetainedValue()` follow ARC ownership rules cleanly. |
| **Entitlements & Logging Privacy** | **CLEAN** | `Resources/iFocus.entitlements` requests only `com.apple.security.device.camera`; `AppController.swift:333,352` logs only numeric `windowID`/`pid`, allowlisted `bundleID`, and enum `rawValue` (never window titles, paths, or commands). |

---

## 3. Confirmed Security Findings

| ID | Sev | Rule | File : Lines | Summary |
| :--- | :---: | :--- | :--- | :--- |
| **SEC-001** | `P1` | `CWE-807` | `Sources/iFocusMac/Input/SystemSessionStateProvider.swift:7-84` | Webcam & AX loop reactivate behind lock screen on `screensDidWake`/`didWake` or spoofed `DistributedNotificationCenter` post; `--calibrate` ignores lock/sleep. |
| **SEC-002** | `P1` | `CWE-1021` | `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:27-28` | `layer == 0` filter strips modal, popup, floating, and security-agent windows (`layer > 0`), blinding `WindowHitTester` occlusion checks. |
| **SEC-003** | `P1` | `CWE-863` | `Sources/iFocusCore/Engine/SafetyPolicy.swift:44-46` | `Config.hardBlocklist` is skipped when `requireAllowedSource == false` and omits `CoreAuthUI` (`com.apple.LocalAuthentication.UIAgent`) & `UserNotificationCenter`. |
| **SEC-004** | `P2` | `CWE-379` | `scripts/sbx.sh:4-34` *(+ `scripts/bundle-app.sh:17-26`)* | Predictable shared `/tmp/ifocus-*` directories used without symlink, UID ownership (`-O`), or `0700` checks before executing tests and signing `dist/iFocus.app`. |
| **SEC-005** | `P2` | `CWE-672` | `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:8-47` | Persistent `bundleIDCache: [Int32: String]` never invalidates exited PIDs, misclassifying windows after macOS PID wraparound (`PID_MAX = 99999`). |
| **SEC-006** | `P2` | `CWE-732` | `Sources/iFocusCore/Storage/SecureFileStore.swift:67-217` | `SecureFileStore.read` silently accepts group/world-writable (`0o775`/`0o777`) config directories and uses pathname-based `lstat`/`open`/`chmod`/`rename` TOCTOU. |
| **SEC-007** | `P2` | `CWE-770` | `Sources/iFocusCore/Engine/FocusCoordinator.swift:42-243` | Unbounded `decisionLog` array appends at 20-30 Hz (~2.6M entries/day), leaking heap memory in the long-running menu-bar agent. |
| **SEC-008** | `P3` | `CWE-636` | `Sources/iFocusMac/App/AppController.swift:274-323` | `runInteractiveCalibration()` fails open on cancel (`Esc`) or error by unconditionally calling `setPaused(false)` and restarting camera capture when previously paused. |

---

### `[SEC-001]` (`P1` | `CWE-807` | Confirmed) Webcam and AX tracking reactivate while locked on screen-wake or spoofed `DistributedNotification`

- **Location:** `Sources/iFocusMac/Input/SystemSessionStateProvider.swift:7-84` (and `Sources/iFocusMac/App/AppController.swift:32-98, 212-221`)
- **Proof Trace:**
  1. User locks their Mac (`com.apple.screenIsLocked` -> `setActive(false)` -> camera stops) and displays sleep (`NSWorkspace.screensDidSleepNotification`).
  2. While the Mac remains locked at `loginwindow`, a notification arrives, the lid opens, or someone bumps the mouse/keyboard, firing `NSWorkspace.screensDidWakeNotification` (or `NSWorkspace.didWakeNotification` on wake from system sleep before password entry).
  3. `SystemSessionStateProvider.swift:40-44` unconditionally calls `self?.setActive(true)` for every notification in `activateNames` without checking whether the session is still locked!
  4. `AppController.sessionTask` (`AppController.swift:214-217`) receives `true` and calls `startTrackingIfReady()`, turning on `AVCaptureSession` (720p webcam LED + Vision inference) and `FocusCoordinator` while the screen is locked.
  5. Independently, `DistributedNotificationCenter.default()` (`lines 19, 25, 31`) is an unauthenticated broadcast IPC bus: any sandboxed or unprivileged local process can post `"com.apple.screenIsUnlocked"` to turn on `iFocus`'s camera while locked/asleep, or post `"com.apple.screenIsLocked"` to silently kill tracking indefinitely. Furthermore, `activeLock` defaults to `true` (`line 7`) if launched while locked, and `AppController.runCalibrateCommand()` (`AppController.swift:32-98`) never observes `SystemSessionStateProvider` at all.
- **Concrete Fix:**
  - Query authoritative WindowServer state via `CGSessionCopyCurrentDictionary()` (`CoreGraphics`): verify `(dict[kCGSessionOnConsoleKey as String] as? Bool ?? true) && !(dict["CGSSessionScreenIsLocked"] as? Bool ?? false)`.
  - Maintain separate `isSystemSleeping` and `isDisplaySleeping` flags driven only by local `NSWorkspace` sleep/wake notifications, recompute `active = !isSystemSleeping && !isDisplaySleeping && isConsoleUnlocked()` on init, on every notification (treating `DistributedNotificationCenter` notifications strictly as hints to re-query `CGSessionCopyCurrentDictionary()`), and inside `isSessionActive()`.
  - Observe `SystemSessionStateProvider` in `AppController.runCalibrateCommand()` (and cancel `CalibrationOverlay` when `active == false`) so CLI calibration also halts camera capture immediately on lock/sleep.

---

### `[SEC-002]` (`P1` | `CWE-1021` | Confirmed) `CGWindowCatalogService` drops `layer != 0` windows, blinding hit-testing to modal and auth dialogs

- **Location:** `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:27-28` (interacting with `Sources/iFocusCore/Targeting/WindowHitTester.swift:5-23`)
- **Proof Trace:**
  1. `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` returns windows front-to-back across all window levels.
  2. `CGWindowCatalogService.swift:28` executes `guard let layer = (entry[kCGWindowLayer] as? NSNumber)?.intValue, layer == 0 else { continue }`, dropping every window at `kCGWindowLayer > 0`.
  3. On macOS, modal alerts (`kCGModalPanelWindowLevel` = 8), floating overlays (`kCGFloatingWindowLevel` = 3, e.g. 1Password Quick Access, Spotlight, Raycast, PIP), popup/context menus (`kCGPopUpMenuWindowLevel` = 101), and system security prompts (`SecurityAgent`, `CoreAuthUI` Touch ID dialog, `UserNotificationCenter` TCC prompt) all sit at `layer > 0`. Many of these (`CoreAuthUI`, `UserNotificationCenter`, accessory panels, menus) do **not** change `NSWorkspace.shared.frontmostApplication` or enable `SecureEventInput` (e.g. Touch ID prompt prior to password fallback, TCC confirmation, or when `respectSecureInput == false`).
  4. When any such `layer > 0` dialog or menu sits over a `layer == 0` terminal window and the user looks at the dialog to read or confirm it, `WindowHitTester.hitTest` (`WindowHitTester.swift:19-22`) never sees the `layer > 0` window in `snapshot.windows`, misses `.blocked` occlusion, and switches keyboard focus to the underlying terminal after `0.30-0.45 s` — dismissing menus or diverting subsequent keystrokes/passphrases into the background shell.
- **Concrete Fix:**
  - Add `public var layer: Int` (defaulting to `0` in `WindowDescriptor.init` to preserve existing call sites/tests) and require `window.layer == 0` in `WindowHitTester.isEligible(_:config:)`.
  - In `CGWindowCatalogService.snapshot()`, keep visible windows with `0 <= layer && layer <= Int(CGWindowLevelForKey(.screenSaverWindow))` (excluding `ownPID`, status-bar strip items where `layer >= Int(CGWindowLevelForKey(.mainMenuWindow)) && bounds.height <= 36`, and non-occluding system desktop chrome `com.apple.WindowManager`, `com.apple.dock`, `com.apple.controlcenter`) so `layer > 0` dialogs/menus/panels participate as `.blocked` occluders in front-to-back z-order.
  - Additionally, if `snapshot.windows` contains any on-screen security prompt (`com.apple.SecurityAgent`, `com.apple.LocalAuthentication.UIAgent`, `com.apple.UserNotificationCenter`, `com.apple.coreservices.uiagent`), veto switching across all displays until the prompt closes.

---

### `[SEC-003]` (`P1` | `CWE-863` | Confirmed) `SafetyPolicy` skips `Config.hardBlocklist` when `requireAllowedSource` is `false` and omits `CoreAuthUI`

- **Location:** `Sources/iFocusCore/Engine/SafetyPolicy.swift:44-46` and `Sources/iFocusCore/Model/Config.swift:16-26, 225-229`
- **Proof Trace:**
  1. `Config.hardBlocklist` (`Config.swift:16-26`) defines security-sensitive apps (`com.apple.SecurityAgent`, `com.apple.loginwindow`, `com.apple.coreservices.uiagent`, `com.apple.systempreferences`, etc.), but `hardBlocklist` is consulted **only** inside `Config.isBundleAllowed(_:)` (`line 227`).
  2. In `DefaultSafetyGuardPolicy.evaluate(_:)` (`SafetyPolicy.swift:44`), source-app checking is written as:
     `if context.config.requireAllowedSource && !context.config.isBundleAllowed(context.frontmostBundleID) { return .deny(.sourceNotAllowed) }`
  3. When a user sets `"requireAllowedSource": false` in `config.json` (documented in `README.md:93` to allow gazing from a browser or IDE into a terminal), `DefaultSafetyGuardPolicy` skips `isBundleAllowed` completely — meaning **`Config.hardBlocklist` is never checked for the frontmost app**!
  4. Furthermore, `Config.hardBlocklist` omits `com.apple.LocalAuthentication.UIAgent` (`CoreAuthUI` Touch ID / admin password prompt), `com.apple.UserNotificationCenter` (TCC prompt), `com.apple.ScreenSharing`, and `com.apple.Settings`. If any of those prompts is frontmost and the user glances at a terminal (before focusing a secure text field, or with `respectSecureInput: false`), `iFocus` steals focus from the security prompt into the terminal.
- **Concrete Fix:**
  - In `DefaultSafetyGuardPolicy.evaluate(_:)`, enforce `Config.hardBlocklist` **unconditionally** before `requireAllowedSource`:
    ```swift
    if let front = context.frontmostBundleID, Config.hardBlocklist.contains(front) {
        return .deny(.sourceNotAllowed)
    }
    if context.config.requireAllowedSource && !context.config.isBundleAllowed(context.frontmostBundleID) {
        return .deny(.sourceNotAllowed)
    }
    ```
  - Expand `Config.hardBlocklist` in `Config.swift` to include `"com.apple.LocalAuthentication.UIAgent"`, `"com.apple.UserNotificationCenter"`, `"com.apple.ScreenSharing"`, and `"com.apple.Settings"`, and add a unit test verifying `hardBlocklist` vetoes even when `requireAllowedSource == false`.

---

### `[SEC-004]` (`P2` | `CWE-379` | Confirmed) Build and app-signing scripts execute and sign binaries from predictable shared `/tmp` directories

- **Location:** `scripts/sbx.sh:4-6, 25-34` and `scripts/bundle-app.sh:17-27, 32-40`
- **Proof Trace:**
  1. By default (`README.md:28-29, 40`), `scripts/sbx.sh` sets `OUT="${IFOCUS_SBX_OUT:-/tmp/ifocus-sbx}"` and runs `mkdir -p "$OUT" "$MC"`, while `scripts/bundle-app.sh --swiftpm` uses hardcoded `/tmp/ifocus-build`, `/tmp/clang-cache`, `/tmp/swiftpm-cache`, and `/tmp/swift-modcache`.
  2. On macOS, `/tmp` (`/private/tmp`) is world-writable (`1777`). `mkdir -p` succeeds silently if `/tmp/ifocus-sbx` was pre-created by another local UID with mode `0777` or as a symlink to another directory.
  3. During `./scripts/sbx.sh test`, a co-tenant user or compromised low-privilege daemon owning `/tmp/ifocus-sbx` can overwrite `$OUT/Runner.swift` or replace `$OUT/tests` prior to line 34 (`"$OUT/tests"`), gaining arbitrary code execution as the developer.
  4. During `./scripts/bundle-app.sh`, replacing `$OUT_DIR/ifocus` before `cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/ifocus"` causes `codesign` (`lines 36-40`) to sign the attacker's Mach-O binary with `IFOCUS_SIGN_IDENTITY` and the `com.apple.security.device.camera` entitlement.
- **Concrete Fix:**
  - Default `IFOCUS_SBX_OUT` to `/tmp/ifocus-sbx-$(id -u)` (and UID-scope `/tmp/ifocus-build-$(id -u)`, `/tmp/clang-cache-$(id -u)`, `/tmp/swiftpm-cache-$(id -u)`, `/tmp/swift-modcache-$(id -u)` in `scripts/bundle-app.sh`).
  - Add a `prepare_secure_dir()` function in both scripts before any read/write:
    ```bash
    prepare_secure_dir() {
      local d="$1"
      mkdir -p -m 0700 "$d"
      if [ -L "$d" ] || [ ! -d "$d" ] || [ ! -O "$d" ]; then
        echo "Refusing insecure scratch directory: $d" >&2
        exit 1
      fi
      chmod 0700 "$d"
    }
    ```

---

### `[SEC-005]` (`P2` | `CWE-672` | Confirmed) Uninvalidated PID-keyed `bundleIDCache` misclassifies windows after macOS PID wraparound

- **Location:** `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:8, 39-47`
- **Proof Trace:**
  1. `CGWindowCatalogService` holds `private var bundleIDCache: [Int32: String] = [:]` across the entire multi-day lifetime of `AppController`.
  2. In `snapshot()`, `if let cached = bundleIDCache[pidNum]` returns the cached `bundleID` without checking whether the original process exited.
  3. After PID wraparound (`PID_MAX = 99999`), any new unprivileged or blocklisted process assigned an exited terminal's PID inherits the cached allowlisted terminal bundle ID, bypassing `WindowHitTester.isEligible` and `Config.hardBlocklist` while growing `bundleIDCache` monotonically.
- **Concrete Fix:**
  - Replace the persistent actor property `bundleIDCache` with a per-`snapshot()` local dictionary `var snapshotBundles: [Int32: String?] = [:]` (resolving `NSRunningApplication(processIdentifier: pidNum)?.bundleIdentifier` at most once per distinct on-screen PID every 200 ms, with zero stale-PID state and zero unbounded retention).

---

### `[SEC-006]` (`P2` | `CWE-732` | Confirmed) `SecureFileStore.read` accepts group/world-writable config directories and uses path-based TOCTOU

- **Location:** `Sources/iFocusCore/Storage/SecureFileStore.swift:57-80, 134-160, 200-217`
- **Proof Trace:**
  1. `SecureFileStore.read(_:)` (`line 67`) calls `try validateDirectoryStat(dirStat, path: dirPath, fixPermissions: false)`.
  2. Inside `validateDirectoryStat` (`lines 210-216`), `if (perms & 0o077) != 0 && fixPermissions` repairs permissions on writes (`fixPermissions == true`) but **does not throw** when `fixPermissions == false`! If `~/Library/Application Support/iFocus` is `0o775` or `0o777`, `read("config.json")` silently trusts the directory, allowing another local user in that group/machine to `unlink` `config.json` (forcing silent fallback to default security policy) or `link(2)` an older `0o600` user-owned config file into place.
  3. Additionally, `lstat(dirPath)` validates the pathname string and then re-resolves `dirPath` from `/` during `chmod(path, ...)`, `open(filePath, ...)`, `open(tmpPath, ...)`, and `rename(tmpPath, destPath)` instead of pinning a directory file descriptor.
- **Concrete Fix:**
  - In `validateDirectoryStat`, when `(perms & 0o022) != 0` (or `(perms & 0o077) != 0`) and `!fixPermissions`, throw `SecureFileStoreError.insecureDirectory("\(path) is group- or world-writable")` (and add this check to `T34` in `FileStoreTests.swift`).
  - Open `let dirFD = open(dirPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)` once, validate `fstat(dirFD, &dirStat)` (and `fchmod(dirFD, safePerms)` when `fixPermissions == true`), and execute `openat(dirFD, filename, ...)`, `openat(dirFD, tmpName, ...)`, `renameat(dirFD, tmpName, dirFD, filename)`, and `unlinkat(dirFD, tmpName, 0)` against `dirFD`.

---

### `[SEC-007]` (`P2` | `CWE-770` | Confirmed) `FocusCoordinator` appends unbounded `DecisionLogEntry` records at 20-30 Hz, leaking heap memory

- **Location:** `Sources/iFocusCore/Engine/FocusCoordinator.swift:42, 182-188, 196-202, 223-229, 236-242`
- **Proof Trace:**
  1. `FocusCoordinator` runs continuously as the core actor of the `LSUIElement` menu-bar agent at `cameraFPS` (`20 Hz` default, up to `30 Hz`).
  2. Every call to `processSingleEvent(_:)` appends a `DecisionLogEntry` to `private var decisionLog: [DecisionLogEntry] = []` with zero eviction or ring-buffer bound, and `stop()` never clears it.
  3. At `30 Hz`, `decisionLog` grows by `108,000` entries/hour (`~2.59M` entries/day), monotonically leaking heap memory until macOS terminates the process.
- **Concrete Fix:**
  - Add a bounded ring buffer / cap on `FocusCoordinator` (e.g., `maxDecisionLogEntries: Int = 4096`, evicting oldest entries once full; `4096` comfortably holds full `60 s` simulation runs of `1,201` steps so `T38` continues to pass unchanged while bounding resident memory below `~400 KiB`).

---

### `[SEC-008]` (`P3` | `CWE-636` | Confirmed) Cancelling or failing interactive calibration silently clears user pause state and starts camera

- **Location:** `Sources/iFocusMac/App/AppController.swift:274-323`
- **Proof Trace:**
  1. A user explicitly pauses `iFocus` via the menu bar or global hotkey (`Paused (Click to Enable)`, camera stopped).
  2. They select `Calibrate...` and press `Esc` (`case .failure(.cancelled)`) or calibration fails (`case .failure(let err)`).
  3. Because `runInteractiveCalibration()` calls `await coordinator.setPaused(true)` (`line 279`) without saving `wasPaused`, lines 321-322 unconditionally call `await coordinator.setPaused(false)` and `await startTrackingIfReady()`, failing open by starting live webcam capture and AX switching despite the user's explicit pause state.
- **Concrete Fix:**
  - Record `let wasPaused = await coordinator.paused()` at the start of `runInteractiveCalibration()`. On `.failure(.cancelled)` or `.failure(_)`, restore `await coordinator.setPaused(wasPaused)` and call `await startTrackingIfReady()` (which will stay paused and keep the camera off when `wasPaused == true`).

---

## 4. Missing Scanners / Environment Notes

- `semgrep` is installed at `/opt/homebrew/bin/semgrep` (`osemgrep`) but exits `2` inside the workspace sandbox when attempting to open `~/.semgrep/settings.yml`. Outside the sandbox (or with local offline rules), run `semgrep scan --config auto` alongside `./scripts/check-invariants.sh`.
