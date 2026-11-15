<!-- Link policy: all links and paths in repo docs must be repo-relative (invariant I8 rejects host home paths and local file URLs). -->
# iFocus Build & Verification Report — Round 3 (Wave 2)

- **Plan:** `docs/plans/final-plan-r3.md`
- **Toolchain:** Apple Swift version 6.4 (`arm64-apple-macosx26.0`), Command Line Tools (`/Library/Developer/CommandLineTools`)
- **Tests:** **93 tests in 17 suites passed** (`T01`–`T78` existing + `T79`–`T93` new; `0` failures, `0` skipped, `0` disabled, `0` compiler `warning:` lines in clean cold `sbx.sh test` output)
- **Test fixtures & guard:** `Config.v1Mechanics` (`Tests/iFocusCoreTests/TestDoubles.swift:6`) preserves pre-Wave-2 timing defaults in **11 tests (`16` occurrences)**: `T16`, `T19`, `T22`, `T25`, `T39`, `T43`, `T51`, `T62`, `T67`, `T70`, `T76`; `CoordinatorTests` carries `@Suite("Coordinator", .timeLimit(.minutes(1)))`. All other existing tests outside those 11 fixture swaps and the 8 planned assertions below pass unedited (`T38` uses the renamed scenario `Scenario.dualExternalTypingThenQuiet()`).
- **Scope & invariants preserved:** `SafetyVeto` keeps 14 cases (`SafetyVeto.allCases.count == 14`), `Config.schemaVersion` stays `1`, removed mismatch config keys are ignored on load, no networking APIs exist in `Sources/` (`I9`), and no host home paths or local file URLs appear in the tree (`I8`).
- **Deviations from plan:** None.
- **Git commit:** Single Round 3 commit on `main` (`Round 3: quiet-then-dwell timing, universal window focus, and public-repo readiness`, parent `ddc35505ba8e1402cce15f80f2448d1e87ff23f7`; exact `HEAD` hash printed by `TMPDIR=/tmp /Library/Developer/CommandLineTools/usr/bin/git rev-parse HEAD` immediately after commit and delivered in the Round 3 handoff board post; nothing pushed).
- **Sandbox SwiftPM notice:** `swift build` and `swift test` cannot run in this sandbox (`xcrun` cache and SwiftPM config writes fail with `Operation not permitted`). Neither command is claimed as passed here; both are **first proven in `.github/workflows/ci.yml` on the first pull request**.

## Reviewer Verification Command (Isolated Sandbox Output)

Use an isolated `IFOCUS_SBX_OUT` directory per reviewer so parallel runs never collide on module caches or binaries:

```bash
IFOCUS_SBX_OUT="/tmp/ifocus-cr-$(id -u)" ./scripts/sbx.sh test
# or for security reviewer:
IFOCUS_SBX_OUT="/tmp/ifocus-sr-$(id -u)" ./scripts/sbx.sh test
```

## I8 Handoff Note (Mandatory for Post-Commit Docs)

Every document added after this commit (reviews, triage, and final report updates) is scanned by invariant `I8` in `scripts/check-invariants.sh` and CI. Use repo-relative links only (never host home paths or local file URLs).

## Verification Gates (`G1b`, `G2`–`G11`)

| Gate | Command | Status & Observed Result / Tail |
|---|---|---|
| **G1b** | `env TMPDIR=/tmp CLANG_MODULE_CACHE_PATH=/tmp/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-cache HOME=/tmp/ifocus-home swift package --disable-sandbox --scratch-path "/tmp/ifocus-build-$(id -u)" describe` | **PASS** (`exit 0`). Printed `iFocusCore`, `iFocusMac`, `iFocusApp` (`Swift languages versions: 6`). |
| **G2 (cold)** | `env IFOCUS_SBX_OUT="/tmp/ifocus-sbx-check-$(id -u)" ./scripts/sbx.sh test` | **PASS** (`exit 0`, `0` `warning:` lines). Tail: `✔ Test run with 93 tests in 17 suites passed after 0.809 seconds.` |
| **G2 (warm)** | `env IFOCUS_SBX_OUT="/tmp/ifocus-sbx-$(id -u)" ./scripts/sbx.sh test \| tail -n 12` | **PASS** (`exit 0`). Tail: `✔ Suite "Scenario" passed after 0.823 seconds.` / `✔ Test run with 93 tests in 17 suites passed after 0.823 seconds.` / `sbx.sh: Command Line Tools layout at /Library/Developer/CommandLineTools`. |
| **G3** | `./scripts/check-invariants.sh` | **PASS** (`exit 0`, re-run after writing `docs/build-r3.md`). Tail: `All invariants passed.` (covers `I1`–`I9` including `I8` and `I9`). |
| **G4** | `"/tmp/ifocus-sbx-$(id -u)/ifocus" --simulate all` | **PASS** (`exit 0`). All 8 scenarios `PASS`: `desk-three`, `dual-external`, `dual-external-before-typing`, `dual-external-typing-then-quiet`, `dual-external-flyover`, `dual-external-type-too-soon`, `mixed-apps-tour`, `mixed-apps-typing-while-reading`. |
| **G5** | `plutil -lint Resources/Info.plist && env IFOCUS_SBX_OUT="/tmp/ifocus-sbx-$(id -u)" ./scripts/bundle-app.sh` | **PASS** (`exit 0`). Tail: `Resources/Info.plist: OK` / `sbx.sh: Command Line Tools layout at /Library/Developer/CommandLineTools` / `dist/iFocus.app: replacing existing signature` / `Bundled and signed dist/iFocus.app`. |
| **G6** | `./scripts/check-scripts.sh` | **PASS** (`exit 0`). Tail: `Script hardening checks passed.` |
| **G7** | `ifocus --version`, `--help`, `--doctor` (from `/tmp/ifocus-sbx-$(id -u)/ifocus`) | **PASS** (`exit 0` each). `--version`: `ifocus 0.1.0`; `--help`: lists `[desk-three\|dual-external\|mixed-apps\|all]`; `--doctor` (home path line redacted for I8): `Live input sample: key=3678.39s click=3680.47s move=3610.01s modifierHeld=no buttonHeld=no`, `Focus scope: allApps`, `Dwell (cross / same): 1.2s / 1.5s, quiet (key / move / click): 2.5s / 2.0s / 2.5s`, 33 windows and 2 `[securityPrompt]` (`prompt veto active: yes`). |
| **G8** | `actionlint .github/workflows/*.yml && zizmor --offline .github/workflows/` | **PASS** (`exit 0` each; default persona per AW7). Tail: `INFO zizmor: 🌈 zizmor v1.31.1` / `No findings to report. Good job! (1 ignored, 1 suppressed)`. |
| **G9** | `cmp -s ~/code/github/agent-skill-forge/.github/workflows/pr-guardian.yml .github/workflows/pr-guardian.yml && shasum -a 256 LICENSE .github/workflows/pr-guardian.yml` | **PASS** (`exit 0`). `cmp-identical`; SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30  LICENSE` (X4) and `f895264c8c614957ab2e904d006727b9df8384f7aafd73ee0b03356cacf8ae1d  .github/workflows/pr-guardian.yml` (X3). |
| **G10** | `python3 ~/code/github/agent-skill-forge/skills/security-review/scripts/run_scanners.py --repo-root .` and `gitleaks dir . --no-banner` | **PARTIAL (`semgrep` offline in sandbox)**: `run_scanners.py` exited `2` (`"status": "partial"`, `leads: []`): `gitleaks` (`ran`, exit `0`, 0 leads), `actionlint` (`ran`, exit `0`, 0 leads), `zizmor` (`ran`, exit `0`, 0 leads), `osv-scanner` (`skipped`: no lockfiles/manifests), `trivy` (`skipped`: no Dockerfiles/IaC/k8s manifests; direct `trivy fs` in sandbox fails offline DB download), `semgrep` (`error`, exit `2` `Dune__exe__Main` / unreachable rule registry). Direct `gitleaks dir . --no-banner`: exit `0`, `11:57PM INF scanned ~1232723 bytes (1.23 MB) in 76.3ms`, `no leaks found`. |
| **G11** | `/Library/Developer/CommandLineTools/usr/bin/git status --porcelain` (post-commit) | Verified empty after single Round 3 commit (`exit 0`, zero untracked or modified files). |

## Contract Changes (8 Edited Existing Tests + Fixture Swaps)

| Test | Location | Before | After |
|---|---|---|---|
| **T26** | `Tests/iFocusCoreTests/SafetyTests.swift:49, 68` | `.typing: .hold`; `.sourceNotAllowed` triggered via `"com.apple.Safari"` | `.typing: .clear`; `.sourceNotAllowed` triggered via blocklisted `"com.apple.systempreferences"` (all 14 vetoes & precedence preserved) |
| **T27** | `Tests/iFocusCoreTests/SafetyTests.swift:99-146` | Tested `Config()` 1.0 s typing hold + 2 mismatch alerts (`alertTimes.count == 2`, switch `>= 3.55`) | Retitled `"T27 typing burst clears the candidate and a fresh dwell follows the quiet period"`; verifies `candidateWindowID == nil` & `dwellProgress == 0` while locked and `1` switch at `>= 6.25` under `Config()` (`2.5 + 1.2`) |
| **T33** | `Tests/iFocusCoreTests/ConfigTests.swift:36` | Clamped `dwellCrossDisplaySeconds == 2.0` | Clamped `dwellCrossDisplaySeconds == 5.0` |
| **T35** | `Tests/iFocusCoreTests/ScenarioTests.swift:25` | `latency <= 1.0` across `deskThree60s` segments | `latency <= 2.0` under `Config()` (`1.2s`/`1.5s` dwell) with identical switch sequence |
| **T36** | `Tests/iFocusCoreTests/ScenarioTests.swift:40` | Switch before typing `< 0.60` | Uses re-timed `dualExternalSwitchBeforeTyping()` (`Scenario.swift:129`); asserts switch precedes typing `< 2.00` |
| **T37** | `Tests/iFocusCoreTests/ScenarioTests.swift:43-55` | `dualExternalMismatchDuringTyping()` checking `!result.mismatchAlerts.isEmpty` + switch `< firstKey + ... >= 2.35` | Uses renamed `dualExternalTypingThenQuiet()` (`Scenario.swift:153`); removes mismatch assertions; asserts 1 switch `>= 5.05` (`1.35 + 2.5 + 1.2`) |
| **T58** | `Tests/iFocusCoreTests/LadderTests.swift:129` | Clock-nil cross-PID failure call count `== 5` | Clock-nil cross-PID failure call count `== 6` (rung B + rung C each end with re-raise) |
| **T72** | `Tests/iFocusCoreTests/LadderTests.swift:215-216` | Rung C cross-PID call count `== 5`, suffix `[.raiseAndMakeMain, .activateApp]` | Rung C cross-PID call count `== 6`, suffix `[.raiseAndMakeMain, .activateApp, .raiseAndMakeMain]` |

*Note on `Config.v1Mechanics` swaps:* Applied exclusively in `T16` (`HitTestTests.swift:54`), `T19` (`EngineTests.swift:35`), `T22` (`EngineTests.swift:170, 180`), `T25` (`EngineTests.swift:251, 259`), `T39` (`SafetyTests.swift:202`), `T43` (`EngineTests.swift:294`), `T51` (`EngineTests.swift:328`), `T62` (`SafetyTests.swift:374, 408`), `T67` (`EngineTests.swift:432`), `T70` (`CoordinatorTests.swift:452, 515`), and `T76` (`HitTestTests.swift:278`).

## Traceability: Upgrades 1–3, RC1–RC5, AW1–AW10 & Closed-by-Inspection Items

### Upgrades 1–3
- **Upgrade 1 — Quiet-then-dwell timing & mismatch retirement:**
  - Config defaults, ranges & decoding (`dwellCrossDisplaySeconds: 1.2`, `dwellSameDisplaySeconds: 1.5`, `typingLockSeconds: 2.5`, `pointerMoveLockSeconds: 2.0`, `pointerClickLockSeconds: 2.5`; removed mismatch keys ignored): `Sources/iFocusCore/Model/Config.swift:76-85, 107-116, 180-189, 218-227` — proven by `T79`, `T83`.
  - `.typing` disposition `.clear`, modifier-held veto, input classes, mismatch removal: `Sources/iFocusCore/Model/FocusTypes.swift:62, 65-75, 166, 248`, `Sources/iFocusCore/Model/InputTypes.swift:5-28`, `Sources/iFocusCore/Engine/SafetyPolicy.swift:55-57, 66`, `Sources/iFocusCore/Engine/FocusDecisionEngine.swift:67, 120, 154, 217, 330-337`, `Sources/iFocusCore/Engine/FocusCoordinator.swift:459` — proven by `T26`, `T27`, `T37`, `T80`, `T81`, `T82`, `T90`, `T91`.
- **Upgrade 2 — Universal window focus (`allApps` + exclusions + blocklist prefixes):**
  - `FocusScope` default `.allApps` (unknown raw string -> `.allowlist`), `excludedBundleIDs` (sanitised, capped at 64), expanded `hardBlocklist` & `hardBlockPrefixes`: `Sources/iFocusCore/Model/Config.swift:3, 21-47, 93-95, 197-203, 236, 245-294`, `Sources/iFocusCore/Targeting/WindowHitTester.swift:12`, `Sources/iFocusCore/Engine/SafetyPolicy.swift:47-50` — proven by `T63`, `T79`, `T84`, `T85`.
- **Upgrade 3 — Cross-PID focus ladder & rollback hardening (`TRG2-02`):**
  - Cross-PID skips Rung A, runs `[.raiseAndMakeMain, .setAppFrontmost, .raiseAndMakeMain]` (Rung B) and `[.raiseAndMakeMain, .activateApp, .raiseAndMakeMain]` (Rung C), re-matches once per step on `.staleCandidate`, verifies `frontmostPID`, `focusedWindowID` & `keyWindowCheck != .differs`, and calls `rollbackIfNeeded` before `.failed(.staleCandidate)` and `.failed(.unverified)`: `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:30-45, 68-138, 180-201`, `Sources/iFocusCore/Simulation/SimServices.swift:138-276, 305-400, 474-483` — proven by `T58`, `T66`, `T68`, `T72`, `T86`, `T87`, `T88`, `T89`, `T92`, `T93`, `G4` (`mixed-apps-tour`).

### Grafted from Plan B (`RC1`–`RC5`) & Arbiter Amendments (`AW1`–`AW10`)
- **RC1 / AW10 (`T93`):** `.alreadyFocused` requires `initial.frontmostPID == target.pid && initial.focusedWindowID == target.windowID`: `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:30` — proven by `T46`, `T93` (`Tests/iFocusCoreTests/LadderTests.swift:385`).
- **RC2:** Runtime self-exclusion appends `Bundle.main.bundleIdentifier` in memory after loading config: `Sources/iFocusMac/App/AppController.swift:141`, `Sources/iFocusMac/App/Doctor.swift:9` — closed by build (`G2`, `G5`) and `--doctor` inspection (`G7`).
- **RC3:** `"CoreAuthUI"` mapped to `com.apple.LocalAuthentication.UIAgent` in `promptOwnerNames`: `Sources/iFocusCore/Model/Config.swift:58`, `Sources/iFocusCore/Targeting/WindowClassifier.swift:17` — proven by `T60`, `T85`.
- **RC4 / AW2:** CI runs `check-invariants.sh` (`:34-35`) and `check-scripts.sh` (`:36-37`) before `swift build`, `swift test`, and `./scripts/sbx.sh test`, after selecting newest non-beta `Xcode_*.app` (`:21-29`): `.github/workflows/ci.yml:1-43` — validated offline by `G8`.
- **RC5:** Guardian workflow byte-identical copy (`pr-guardian.yml`, 81 lines) and `LICENSE` (Apache-2.0, 202 lines) verified by `cmp -s` and `shasum -a 256`: `G9`.
- **AW1 / AW10 (`T92`):** `verificationAttempts = crossPID ? 8 : 3` (8 polls 50 ms apart cross-PID; 3 same-PID): `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:45, 123` — proven by `T92` (`Tests/iFocusCoreTests/LadderTests.swift:345`).
- **AW3:** `watchedModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]` (excludes `fn`/Caps Lock), mouse-up (`leftMouseUp`, `rightMouseUp`, `otherMouseUp`) + `scrollWheel` in click class, `--doctor` prints `Live input sample`: `Sources/iFocusMac/Input/SystemInputActivityProvider.swift:15-52`, `Sources/iFocusMac/App/Doctor.swift:31-35` — closed by build (`G2`, `G5`) and `--doctor` run (`G7`).
- **AW4:** `scripts/sbx.sh` explicit CLT-first then Xcode toolchain probe without calling `xcrun` when explicit paths exist: `scripts/sbx.sh:36-47` — CLT branch proven by `G2` and `G5`; Xcode branch untested locally (settled in CI).
- **AW5:** `docs/FINAL_REPORT.md` host paths and local file URLs scrubbed, line-1 I8 HTML comment added, `## Wave 2 Addendum (Round 3)` appended (22 lines added inside the 25-line budget); `docs/plans/plan-b-r1.md:4` scrubbed — proven by `I8` in `G3`.
- **AW6:** Invariant `I9` forbids networking APIs (`URLSession`, `URLRequest`, `NWConnection`, `NWListener`, `import Network`, `CFSocket`, `NSURLConnection`) across `Sources/`: `scripts/check-invariants.sh:162-163` — proven by `G3`.
- **AW7:** `zizmor --offline .github/workflows/` executed in default persona (`G8`): `exit 0`, zero findings.
- **AW8:** Password managers (`com.1password.1password`, `com.apple.Passwords`, `com.bitwarden.desktop`, `com.agilebits.onepassword7`) and `com.apple.keychainaccess` blocked in `hardBlocklist` as targets and sources without raising the global prompt veto: `Sources/iFocusCore/Model/Config.swift:21-40`, `Sources/iFocusCore/Engine/SafetyPolicy.swift:47` — proven by `T63`, `T84`, `T85`.
- **AW9:** Status menu reports `"Waiting for input to go quiet"` when `.typing` veto is active: `Sources/iFocusMac/UI/StatusMenuController.swift:112` — closed by build (`G2`, `G5`) and inspection.
- **Public-repo documents & mismatch removal closed by build/inspection:** `LICENSE` (202 lines), `SECURITY.md` (27 lines), `CONTRIBUTING.md` (47 lines), `DESIGN.md` (142 lines), `README.md` (150 lines); `--doctor` window eligibility diagnostics & 6-window `--focus-test` cap (`Sources/iFocusMac/App/Doctor.swift:49-54, 148, 190-193`); mismatch removal in `Sources/iFocusMac/UI/HUDController.swift:56`, `Sources/iFocusMac/App/AppController.swift:381-388`, `Sources/iFocusApp/IFocusCLI.swift:108-127`, `Sources/iFocusCore/Simulation/Scenario.swift:42, 44, 129, 153, 227, 254, 283`, `Sources/iFocusCore/Simulation/ScenarioRunner.swift:78, 100-116, 234-330`, `Sources/iFocusCore/Simulation/Presets.swift:21, 205`.

### New Tests Added (`T79`–`T93`)

| Test | File & Line | Coverage |
|---|---|---|
| **T79** | `Tests/iFocusCoreTests/ConfigTests.swift:73` | New Wave 2 defaults & clamping bounds, `focusScope` decode & unknown fallback, ignored legacy mismatch keys, `excludedBundleIDs` sanitisation & 64-entry cap |
| **T80** | `Tests/iFocusCoreTests/EngineTests.swift:523` | `typingLockSeconds` (2.5 s) + `dwellCrossDisplaySeconds` (1.2 s) restart on 150 ms bursts and mid-dwell keystroke |
| **T81** | `Tests/iFocusCoreTests/SafetyTests.swift:457` | All 5 input classes (keyboard, modifier held, pointer click 2.5 s, pointer move 2.0 s, button held) clear & require full quiet + fresh dwell |
| **T82** | `Tests/iFocusCoreTests/EngineTests.swift:610` | Dropout veto interleaved with typing cannot preserve candidate across lock |
| **T83** | `Tests/iFocusCoreTests/EngineTests.swift:684` | Idle-hands default dwell thresholds (`1.2 s` cross-display, `1.5 s` same-display) |
| **T84** | `Tests/iFocusCoreTests/HitTestTests.swift:318` | Eligibility across `allApps`, `hardBlocklist`, `hardBlockPrefixes`, nil/empty, `excludedBundleIDs`, layer > 0, tiny windows, `allowlist` |
| **T85** | `Tests/iFocusCoreTests/SafetyTests.swift:565` | 1Password / Spotlight occlusion, password-manager frontmost veto without global prompt leak (AW8), `CoreAuthUI` prompt alias (RC3) |
| **T86** | `Tests/iFocusCoreTests/LadderTests.swift:234` | Ghostty -> Spotify on `Rig.mixedApps` via `.rungB` (exact 3 steps, skips Rung A, verifies `keyWindowCheck == .matches`) |
| **T87** | `Tests/iFocusCoreTests/LadderTests.swift:254` | Cross-PID Chrome background window 2 (with `ignoreRaiseWhileAppInBackground`) -> Chrome window 1 `.rungA` (with & without window IDs) |
| **T88** | `Tests/iFocusCoreTests/LadderTests.swift:281` | Raise without app activation -> `.failed(.unverified)` with rollback; stale after wrong raise rolls back (`TRG2-02`) |
| **T89** | `Tests/iFocusCoreTests/ScenarioTests.swift:173` | `mixedAppsTour` via `runWithLadder` across 10 seeds (`rungB` on app changes, `rungA` intra-Chrome) |
| **T90** | `Tests/iFocusCoreTests/ScenarioTests.swift:215` | `mixedAppsTypingWhileReading` across 10 seeds: zero candidate entries across 1.5 s pause + 2.5 s quiet, 1 switch `[+3.7 s, +4.2 s]` |
| **T91** | `Tests/iFocusCoreTests/ScenarioTests.swift:241` | `dualExternalTypeTooSoon` produces 0 switches (look-then-type tradeoff) |
| **T92** | `Tests/iFocusCoreTests/LadderTests.swift:345` | AW1: 0.2 s `activationLatencySeconds` succeeds on `.rungB` with 8-poll window, 3 steps, 0 rollbacks; same-PID stays at 3 polls |
| **T93** | `Tests/iFocusCoreTests/LadderTests.swift:385` | RC1: mismatched `frontmostPID` with matching `focusedWindowID` does not return `.alreadyFocused` and runs cross-PID rungs |

## Unverified Items Offline & Where Settled

| Item | Why Unverified Offline | Where Settled |
|---|---|---|
| Runner compiler accepting Swift 6.4 source (`AW2`) | Only Swift 6.4 CLT is installed locally; runner default macOS 15 Xcode may be older | First `.github/workflows/ci.yml` PR run (`Select the newest installed Xcode` + `Show toolchain`) |
| Xcode branch of `scripts/sbx.sh` probe (`AW4`) | No `Xcode.app` installed locally | First CI run (`./scripts/sbx.sh test` step in `.github/workflows/ci.yml`) |
| `semgrep` scan (`G10`) | Rule packs require an unreachable online registry (`exit 2` in sandbox) | First pull request (`pr-guardian.yml` / connected security run) |
| Live cross-app AX activation & real activation latency (`AW1`) | No Accessibility permission grant in headless sandbox | Desk checklist steps 12, 13, and 16 (`README.md`) |
| Real Spotlight window layer and bounds (`AW8`) | Screen locked during all verification rounds | Desk checklist step 17 (`README.md`) |
| Bitwarden & 1Password 7 exact bundle identifiers (`AW8`) | Neither app is installed on the sandbox host | `--doctor` on a machine with those apps installed (`excludedBundleIDs` covers overrides) |
