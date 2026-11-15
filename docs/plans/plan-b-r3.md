# iFocus Wave 2 Upgrade & GitHub Readiness Plan (Plan B - Round 3)

**Author Role:** `planner-b` (Systems, Computer Vision & macOS Accessibility Specialist)  
**Target Baseline:** `ddc35505ba8e161701e8ca7784259caa241eaf1e` (`main`)  
**Scope:** Wave 2 feature upgrades (`2.5 s` activity-quiet + `1.2/1.5 s` fresh dwell, universal `allApps` focus + cross-PID accuracy) and public GitHub / `pr-guardian` CI readiness, plus minor non-blocking Round 2 polish where tightly coupled.

---

## 1. Executive Summary & Architectural Shifts

Wave 2 upgrades `iFocus` from a terminal-only v1 prototype with a `1.0 s` `.hold` typing pre-charge into a universal macOS desktop focus manager tailored to a **1-2 windows side-by-side per monitor across 3 displays** workflow, and hardens the repository for public GitHub publication under `pr-guardian`:

1. **Activity-Quiet (`2.5 s`) + Fresh Gaze Dwell (`1.2 s` / `1.5 s`) Model:**
   - Change `SafetyVeto.typing.disposition` from `.hold` to `.clear` so any keyboard (`keyDown`, `keyUp`, `flagsChanged`), pointer (`mouseMoved`, drag, scroll), or mouse-click activity **immediately clears** `pending` and `challenger` dwell state (`dwellProgress = 0`) and suppresses accumulation for the full quiet window (`typingLockSeconds = 2.5`, `pointerMoveLockSeconds = 2.0`, `pointerClickLockSeconds = 2.5`).
   - Only **after** the quiet window expires does a fresh continuous dwell start from `0.0 s` (`dwellCrossDisplaySeconds = 1.2`, `dwellSameDisplaySeconds = 1.5`), eliminating accidental reference-reading switches after typing pauses (`3.7-4.0 s` post-keystroke) while keeping idle-hand glances fast (`1.2 s` cross-display).
   - Retire the legacy `.typing` pre-charge `mismatchAlert` trigger cleanly from `FocusDecisionEngine`, `FocusTypes`, `AppController`, `HUDController`, `ScenarioRunner`, and `IFocusCLI` (keeping `Config.init(from:)` tolerant of legacy JSON keys).
2. **Universal Desktop Window Focus (`focusScope = .allApps` Default) + Cross-PID Accuracy:**
   - Add `FocusScope` (`allApps` default, `allowlist` opt-in) to `Config`, allowing `iFocus` to focus `Chrome`, `Spotify`, `Ghostty`, editors, and standard `layer == 0` app windows out of the box while unconditionally blocking auth prompts (`SecurityAgent`, `CoreAuthUI` / `LocalAuthentication.UIAgent`, `UserNotificationCenter`, `coreservices.uiagent`), password managers (`1Password`, `Bitwarden`, `Keychain Access`), lock/screen-sharing (`loginwindow`, `ScreenSaver.Engine`, `ScreenSharing`), system chrome (`Dock`, `WindowManager`, `ControlCenter`, `NotificationCenter`, `Spotlight`, `SystemUIServer`), and `iFocus` itself (`dev.ifocus.app` / `Bundle.main.bundleIdentifier`).
   - Upgrade `LadderFocusSwitcher` and `AXActuator` for **cross-PID vs same-PID** accuracy: cross-PID transitions (`initial.frontmostPID != target.pid`, e.g., `Ghostty -> Spotify` or `Ghostty -> Chrome #2`) skip Rung A (which cannot activate a background PID), start directly at Rung B (`[.raiseAndMakeMain, .setAppFrontmost]`) -> Rung C (`[.raiseAndMakeMain, .activateApp]`), re-assert raise/main/focus after `NSRunningApplication.activate(options: [])` so multi-window apps (`Chrome`) surface the exact `CGWindowID`-matched window rather than their prior key window, and verify **both** `frontmostPID == target.pid` and `focusedWindowID == target.windowID`.
3. **Public GitHub Repository & `pr-guardian` CI Readiness:**
   - Add `LICENSE` (Apache-2.0), `SECURITY.md`, `CONTRIBUTING.md`, comprehensive `DESIGN.md`, and updated `README.md` + `docs/FINAL_REPORT.md`.
   - Copy `../agent-skill-forge/.github/workflows/pr-guardian.yml` byte-for-byte to `.github/workflows/pr-guardian.yml` and add a SHA-pinned, least-privilege `.github/workflows/ci.yml` (`macos-15`) passing `actionlint` and `zizmor --offline` with zero findings.
   - Update `scripts/sbx.sh` to resolve both CommandLineTools and Xcode toolchains cleanly so `check-scripts.sh` passes on GitHub `macos-15` runners too.
   - Scrub all host-specific user home paths from all tracked files (`docs/FINAL_REPORT.md`, `docs/plans/plan-b-r1.md`, etc.) and enforce a host-path invariant (`I8`) in `scripts/check-invariants.sh`.

---

## 2. Detailed Design by Subsystem

### 2.1 Activity-Quiet (`2.5 s`) + Fresh Dwell (`1.2 s` / `1.5 s`) State Machine

| Component | Target File(s) | Exact Change |
| :--- | :--- | :--- |
| **`Config` Timing Defaults & Ranges** | `Sources/iFocusCore/Model/Config.swift` | Update defaults and clamping ranges: `dwellCrossDisplaySeconds: 1.2` (`0.15...5.0`), `dwellSameDisplaySeconds: 1.5` (`0.15...5.0`), `typingLockSeconds: 2.5` (`0.3...10.0`), `pointerMoveLockSeconds: 2.0` (`0...10.0`), `pointerClickLockSeconds: 2.5` (`0...10.0`). Remove `mismatchAlert`, `mismatchBeep`, `mismatchAlertIntervalSeconds` (note `Codable` `CodingKeys` omitting them ensures legacy `config.json` files decode cleanly without throwing on unknown keys). |
| **Input Activity Tracking** | `Sources/iFocusMac/Input/SystemInputActivityProvider.swift` | Include `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyUp)` alongside `.keyDown` and `.flagsChanged` (`min(sinceKeyDown, min(sinceKeyUp, sinceFlagsChanged))`) so releasing a held key starts the `2.5 s` quiet window cleanly. Retain `.mouseMoved`, `.leftMouseDragged`, `.rightMouseDragged`, `.otherMouseDragged`, `.scrollWheel`, mouse-downs, and `buttonState`. |
| **`.typing` Veto Disposition** | `Sources/iFocusCore/Model/FocusTypes.swift` | Change `SafetyVeto.typing.disposition` from `.hold` to `.clear` (leaving only `.cooldown` as `.hold`). Retire `EngineAction.mismatchAlert` and `CoordinatorEvent.mismatch` cleanly (along with `HUDController.flashMismatch` and mismatch tracking in `ScenarioRunner` / `IFocusCLI` / `AppController`), so staring at a reference browser while typing in a terminal produces zero amber false-alarm flashes. |
| **Decision Engine Reset** | `Sources/iFocusCore/Engine/FocusDecisionEngine.swift` | Because `.typing.disposition == .clear`, `step(_:)` clears `pending = nil`, `challenger = nil`, and returns `dwellProgress = 0.0` on every frame during typing or within `2.5 s` after the last input event. In `evaluatePendingCommit(...)`, remove the retired `case .typing:` branch (leaving only `nil` and `.cooldown` hold-commit). Dwell only starts at `0.0 s` on the first sample **after** all activity quiet windows (`2.5 s` keyboard/click, `2.0 s` move/drag/scroll) expire, committing only after `1.2 s` (cross-display) or `1.5 s` (same-display) of fresh continuous dwell. |

### 2.2 Universal App Focus (`allApps`), Security Blocklist & Cross-PID Focus Ladder

| Component | Target File(s) | Exact Change |
| :--- | :--- | :--- |
| **`FocusScope` & Unconditional Blocklist** | `Sources/iFocusCore/Model/Config.swift`<br>`Sources/iFocusCore/Targeting/WindowClassifier.swift`<br>`Sources/iFocusCore/Targeting/WindowHitTester.swift`<br>`Sources/iFocusCore/Engine/SafetyPolicy.swift` | Add `public enum FocusScope: String, Sendable, Equatable, Codable { case allApps, allowlist }` and `public var focusScope: FocusScope = .allApps` on `Config` (decoded via `decodeIfPresent ?? .allApps`). Expand `Config.hardBlocklist` and `Config.promptOwnerNames` / `WindowClassifier.canonicalBundleID` to cover: `"com.apple.keychainaccess"`, `"com.1password.1password"`, `"com.agilebits.onepassword7"`, `"2BUA8C4S2C.com.1password.browser-helper"`, `"com.bitwarden.desktop"`, `"com.apple.CoreAuthUI"`, `"com.apple.CoreAuthentication.daemon"`, `"com.apple.Spotlight"`, `"com.apple.systemuiserver"`, `"com.apple.screensharing.agent"`, and self (`"dev.ifocus.app"`), plus `ownerName` fallbacks (`"1Password"`, `"Bitwarden"`, `"Keychain Access"`, `"Spotlight"`, `"SystemUIServer"`, `"CoreAuthUI"`). Add `isBundleEligible(_ bundleID: String?, ownBundleID: String? = nil)` on `Config`: always rejects `nil`/empty, self (`ownBundleID` or `"dev.ifocus.app"`), `hardBlocklist`, `securityPromptBundleIDs`, `chromeBundleIDs`; when `.allApps`, allows any remaining bundle ID; when `.allowlist`, requires `allowedBundleIDs.contains`. In `DefaultSafetyGuardPolicy.evaluate`, enforce `hardBlocklist` / `securityPromptBundleIDs` / `chromeBundleIDs` unconditionally on `frontmostBundleID`, and apply `allowedBundleIDs` check only when `context.config.focusScope == .allowlist && context.config.requireAllowedSource`. |
| **Own-Bundle Self-Exclusion & Menu Scope Toggle** | `Sources/iFocusMac/Windows/CGWindowCatalogService.swift`<br>`Sources/iFocusMac/UI/StatusMenuController.swift`<br>`Sources/iFocusMac/App/AppController.swift`<br>`Sources/iFocusMac/App/Doctor.swift` | Pass `ownBundleID = Bundle.main.bundleIdentifier` (alongside `ownPID`) into `WindowClassifier` / `WindowHitTester` so `iFocus` never targets itself. Add a menu bar toggle (`"Scope: All Apps"` / `"Scope: Allowlist Only"`) in `StatusMenuController` wired to `AppController` -> `coordinator.updateConfig(...)` (persisting or toggling live cleanly), and print `focusScope` in `Doctor`. |
| **Cross-PID vs Same-PID Ladder** | `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift`<br>`Sources/iFocusMac/Focus/AXActuator.swift`<br>`Sources/iFocusCore/Simulation/SimServices.swift` | 1. In `LadderFocusSwitcher.focus(_ target:)`: compute `isCrossPID = (initial.frontmostPID != target.pid)`. Require `initial.frontmostPID == target.pid && initial.focusedWindowID == target.windowID` for `.alreadyFocused`. When `isCrossPID`, **skip `.rungA`** and run `[(.rungB, [.raiseAndMakeMain, .setAppFrontmost]), (.rungC, [.raiseAndMakeMain, .activateApp])]`; when same-PID, keep `[.rungA, .rungB, .rungC]`.<br>2. In `AXActuator.perform(.activateApp, ...)`: after `NSRunningApplication(processIdentifier: pid)?.activate(options: [])` succeeds on `@MainActor`, immediately re-assert `kAXRaiseAction`, `kAXMainAttribute = true`, and `kAXFocusedAttribute = true` on `targetElement` so multi-window background apps (`Google Chrome` with 2+ windows) focus the exact `CGWindowID`-matched window instead of their prior key window.<br>3. In `LadderFocusSwitcher.verifyFocused(...)`: require **BOTH** `snap.frontmostPID == target.pid` AND `snap.focusedWindowID == target.windowID`, plus `keyWindowCheck(pid:expected:) != .differs`. In `AXActuator.keyWindowCheck(pid:expected:)`, verify `NSWorkspace.shared.frontmostApplication?.processIdentifier == pid` on `@MainActor` (returning `.differs` if another PID is frontmost) before inspecting `kAXFocusedWindowAttribute`.<br>4. Include `TRG2-02` polish cleanly: if returning `.staleCandidate` after an earlier rung mutated focus away from `initial.focusedWindowID`, invoke `rollbackIfNeeded(...)`. |

### 2.3 Public GitHub Repository, `pr-guardian` CI & Toolchain Portability

| Artifact | Purpose & Exact Contents |
| :--- | :--- |
| **`LICENSE`** | Standard Apache License 2.0 text (`Copyright 2026 The iFocus Authors`). |
| **`SECURITY.md`** | Threat model & TCC boundary (Camera + Accessibility only, zero `CGEventTap`/keylogging, zero disk frame persistence, zero network I/O, `0700`/`0600` `O_NOFOLLOW` `SecureFileStore`, lock-screen `CGSessionCopyCurrentDictionary` fail-closed gating) + private vulnerability reporting instructions. |
| **`CONTRIBUTING.md`** | Build/test commands (`swift test`, `./scripts/sbx.sh test`, `./scripts/check-invariants.sh`, `./scripts/check-scripts.sh`, `actionlint`, `zizmor --offline`), Swift 6 strict-concurrency & `I1`–`I8` invariant rules, PR expectations under `pr-guardian`. |
| **`DESIGN.md`** | Deep technical architecture dossier covering coordinate transforms (`H_0` primary-height Quartz/AppKit flip, physical mm topology), Vision rev3 + inter-canthal eye de-roll + `EAR` blink hold + `OneEuroFilter2D` + per-display Ridge calibration, 9-rule `WindowClassifier` + `WindowHitTester`, cross-PID vs same-PID `AXUIElement` focus ladder, `2.5 s` quiet + `1.2/1.5 s` fresh dwell 14-veto FSM, and security/privacy design. |
| **`README.md` & `docs/FINAL_REPORT.md`** | Update defaults/tables/workflow documentation for universal `allApps` focus, `2.5 s` quiet + `1.2/1.5 s` fresh dwell, retired `mismatchAlert`, CI workflows, and remove all machine-specific home paths (converting links to relative paths like `Sources/...`). |
| **`.github/workflows/pr-guardian.yml`** | Copied **byte-for-byte** (`cmp -s`) from `../agent-skill-forge/.github/workflows/pr-guardian.yml`. |
| **`.github/workflows/ci.yml`** | `permissions: contents: read`, `concurrency` group per workflow+ref, `runs-on: macos-15`, `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` (`persist-credentials: false`), running `./scripts/check-invariants.sh`, `./scripts/check-scripts.sh`, `swift build`, `swift test`, `./scripts/sbx.sh test`, and `./scripts/bundle-app.sh --swiftpm`. |
| **`scripts/sbx.sh` & `scripts/check-invariants.sh`** | Update `scripts/sbx.sh` to locate `swiftc`, `MacOSX.sdk`, `Testing.framework`, and the testing plugin directory on **both** CommandLineTools (`/Library/Developer/CommandLineTools`) and Xcode (`XcodeDefault.xctoolchain` + `MacOSX.platform`) layouts so `sbx.sh` and `check-scripts.sh` pass on GitHub `macos-15` runners too. Add invariant `I8` in `scripts/check-invariants.sh` scanning all repo text/source/docs/workflow files (`Sources`, `Tests`, `scripts`, `docs`, `Resources`, `.github`, `README.md`, `DESIGN.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`, `Package.swift`) for literal `/[U]sers/[A-Za-z0-9._-]+` paths and failing if any remain; also scrub `docs/plans/plan-b-r1.md` and `docs/FINAL_REPORT.md`. |

---

## 3. Reconciled Round 1/2 Tests & New Round 3 Acceptance Tests (`T79`–`T86`)

### 3.1 Intentional Test Reconciliations (Contract Changes Explicitly Documented)

| Test ID(s) | Reason for Update | Exact Update |
| :--- | :--- | :--- |
| **`T16`, `T17`** (`HitTestTests.swift`) | Under `focusScope = .allApps` default, `Safari` is now an eligible browser window; `1Password`/`SecurityAgent`/`systempreferences` remain blocked. | Assert `.allApps` returns `.window(safari)` while `1Password`/`systempreferences` return `.blocked` / block closer snap, and explicit `.allowlist` config reproduces `.blocked` / snap rejection for `Safari`. |
| **`T19`, `T22`, `T42`, `T43`, `T51`, `T67`, `T70`** (`EngineTests.swift`, `CoordinatorTests.swift`) | Default dwell thresholds changed (`0.30/0.45 s` -> `1.20/1.50 s`). | Update `T19`/`T22`/`T43`/`T51`/`T67`/`T70` step durations or timestamps to `1.20 s` / `1.50 s` defaults (and configure explicit `dwellCrossDisplaySeconds = 0.30` in `T42` so cooldown `.hold` deferral remains crisp at `t = 1.60 s`). |
| **`T26`, `T27`** (`SafetyTests.swift`) | `SafetyVeto.typing.disposition` is now `.clear` (not `.hold`); `.sourceNotAllowed` triggers on blocklisted apps in `.allApps` or non-allowlisted apps in `.allowlist`; typing-hold `mismatchAlert` retired. | Update `T26` expected `.typing.disposition == .clear` and `.sourceNotAllowed` using `"com.1password.1password"` (plus `.allowlist` check with Safari). Update `T27` to prove typing bursts wipe dwell (`candidateWindowID == nil`, `dwellProgress == 0`) and switching commits only after `2.5 s` quiet + `1.2 s` fresh dwell (`>= 3.70 s` post-last-key). |
| **`T31`, `T58`, `T72`** (`LadderTests.swift`) | Cross-PID switches skip Rung A (`[.raiseAndMakeMain]`). | `T31` cross-PID starts at Rung B (`.switched(.rungB)` / `.rungC`); `T58` & `T72` cross-PID expected `performCalls.count` is `4` (Rung B 2 + Rung C 2) with zero Rung A calls. |
| **`T33`** (`ConfigTests.swift`) | New clamping ceilings/defaults (`dwell` `0.15...5.0`, `typingLock` `0.3...10.0`, `pointer` `0...10.0`, `focusScope = .allApps`). | Assert `99.0` dwell clamps to `5.0`, defaults match Wave 2 values, and `focusScope` round-trips & defaults cleanly. |
| **`T35`, `T36`, `T37`, `T44`** (`Scenario.swift`, `ScenarioTests.swift`) | Default `1.2/1.5 s` dwell + `2.5 s` `.clear` quiet window. | `T35` latency bound `<= 2.0 s`; `T36` typing starts at `1.60 s` (after `1.20 s` cross-display switch); `T37` extends duration to `6.0 s` proving zero switch during typing + `2.5 s` quiet and clean switch after `1.35 + 2.50 + 1.20 = 5.05 s`. |

### 3.2 New Wave 2 Acceptance Tests (`T79`–`T86`)

| ID | Suite File | Proves |
| :--- | :--- | :--- |
| **`T79`** | `LadderTests.swift` | Cross-PID `Ghostty -> Spotify` skips Rung A, activates `Spotify` (`.rungB`/`.rungC`), and `verifyFocused` fails if `focusedWindowID` changes while `frontmostPID` stays `Ghostty`. |
| **`T80`** | `LadderTests.swift` & `HitTestTests.swift` | Multi-window `Chrome` (2 side-by-side windows sharing one `com.google.Chrome` PID with distinct `windowID`s): switching `Ghostty -> Chrome #2` skips Rung A and focuses exact `#2` (never `#1`), whereas subsequent same-PID `Chrome #2 -> Chrome #1` starts at `.rungA`. |
| **`T81`** | `EngineTests.swift` | Reference-reading workflow: typing in `Ghostty` while gazing at `Chrome` for `10.0 s`, pausing to think for `1.5 s` (`< 2.5 s` quiet) -> zero switches and `dwellProgress == 0` throughout; continuing gaze through `2.5 s` quiet + `1.2 s` fresh dwell (`>= 3.7 s` after last key) -> commits switch cleanly. |
| **`T82`** | `EngineTests.swift` & `SafetyTests.swift` | Idle-hand `Ghostty -> Spotify` switch commits in `1.2 s` (`dwellCrossDisplaySeconds`); pointer move/drag/scroll (`pointerMoveLockSeconds = 2.0`) and click (`pointerClickLockSeconds = 2.5`) wipe `pending` (`dwellProgress == 0`) and require full fresh dwell after quiet expiry. |
| **`T83`** | `SafetyTests.swift` & `HitTestTests.swift` | `FocusScope.allApps` allows `com.google.Chrome`, `com.spotify.client`, `com.apple.Safari`, `com.microsoft.VSCode` while unconditionally blocking `1Password`, `Bitwarden`, `Keychain Access`, `Spotlight`, `SystemUIServer`, `ScreenSharing`, `SecurityAgent`, `coreautha`, and `dev.ifocus.app`; switching `focusScope` to `.allowlist` blocks `Chrome` and `Spotify`. |
| **`T84`** | `ConfigTests.swift` | Legacy v1 `config.json` (lacking `focusScope`, containing legacy `mismatchAlert` keys) decodes cleanly with `focusScope == .allApps` and Wave 2 defaults; clamping enforces `0.3...10.0` on `typingLockSeconds` and `0...10.0` on pointer locks. |
| **`T85`** | `HitTestTests.swift` | `WindowClassifier.canonicalBundleID` & `classify` handle password manager and system chrome `ownerName` aliases (`"1Password"`, `"Bitwarden"`, `"Keychain Access"`, `"Spotlight"`, `"SystemUIServer"`, `"CoreAuthUI"`). |
| **`T86`** | `ScenarioTests.swift` | End-to-end Wave 2 scenarios in `Presets.swift` / `Scenario.swift` (`idleSpotifySwitch`, `ghosttyChromeDualWindow`, `ghosttyTypingWhileReadingChrome`) run through `FocusCoordinator` + `LadderFocusSwitcher` with exact expected switch sequences and timestamps. |

---

## 4. Task Sequencing & Verification Gates

1. **Stage 1 (`iFocusCore` Core Contract):** `Config.swift`, `FocusTypes.swift`, `WindowClassifier.swift`, `WindowHitTester.swift`, `SafetyPolicy.swift`, `FocusDecisionEngine.swift`, `LadderFocusSwitcher.swift`, `Scenario.swift`, `ScenarioRunner.swift`, `Presets.swift`.
2. **Stage 2 (`iFocusMac` & `iFocusApp`):** `SystemInputActivityProvider.swift`, `CGWindowCatalogService.swift`, `AXActuator.swift`, `HUDController.swift`, `StatusMenuController.swift`, `AppController.swift`, `Doctor.swift`, `IFocusCLI.swift`.
3. **Stage 3 (Tests):** Reconcile `T16`–`T72` intentionally per §3.1 and add `T79`–`T86` (`86` total tests).
4. **Stage 4 (GitHub, Docs, Scrubbing & CI Gates):**
   - Add `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, `DESIGN.md`, `.github/workflows/ci.yml`, byte-identical `.github/workflows/pr-guardian.yml`.
   - Scrub all `/[U]sers/<user>` strings from `docs/FINAL_REPORT.md`, `docs/plans/plan-b-r1.md`, and update `README.md`, `scripts/sbx.sh`, `scripts/check-invariants.sh` (`I8`).
   - Run full verification gates (zero warnings, exit `0`):
     1. `./scripts/check-invariants.sh` (including `I8` zero host paths)
     2. `./scripts/check-scripts.sh`
     3. `IFOCUS_SBX_OUT="/tmp/ifocus-r3-$(id -u)" ./scripts/sbx.sh test` (`86/86` passing)
     4. `IFOCUS_SBX_OUT="/tmp/ifocus-r3-$(id -u)" ./scripts/bundle-app.sh` (`dist/iFocus.app` signed & verified)
     5. `swift package --disable-sandbox describe`
     6. `actionlint .github/workflows/ci.yml .github/workflows/pr-guardian.yml`
     7. `zizmor --offline .github/workflows/ci.yml .github/workflows/pr-guardian.yml`
     8. `cmp -s ../agent-skill-forge/.github/workflows/pr-guardian.yml .github/workflows/pr-guardian.yml`
     9. `gitleaks detect --no-banner --source .` & `trivy fs --scanners vuln,misconfig,secret .`
     10. `--simulate all --seed 1`, `--doctor`, `--help`, `--version` (`exit 0`)
