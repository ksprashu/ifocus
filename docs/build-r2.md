# iFocus Build & Verification Report — Round 2

- **Plan:** `docs/plans/final-plan-r2.md`
- **Triage source:** `docs/reviews/triage-r1.md` (`TRG-01`–`TRG-28`, keeping `DEF-01` and `DEF-02` deferred)
- **Toolchain:** Apple Swift version 6.4 (`arm64-apple-macosx26.0`), Command Line Tools (`/Library/Developer/CommandLineTools`)
- **Tests:** **78 tests in 17 suites passed** (`T01`–`T54` existing + `T55`–`T78` new; `0` failures, `0` skipped, `0` disabled, `0` compiler `warning:` lines)
- **Test-diff invariant:** `T01`–`T50`, `T52`–`T54`, and `T51`'s failure assertions remain byte-identical to commit `fb078be3ba8e161701e8ca7784259caa241eaf1e`; `T51` adds one unperturbed positive control run (`#expect(switchedUnperturbed.count == 1)`).
- **Test mapping note:** **T71 is the dispatch's T34 extension, T76 its T17 extension.**
- **Scope & invariants preserved:** `SafetyVeto` keeps 14 cases, zero new `Config` keys added, and calibration profile version unchanged.
- **Deviations from plan:** None.
- **Git commit:** Single Round 2 commit on `main` (`Round 2: ...`, parent `fb078be3ba8e161701e8ca7784259caa241eaf1e`; exact commit hash printed by `TMPDIR=/tmp git rev-parse HEAD` and delivered in the Round 2 handoff board post).

## Reviewer Verification Command (Isolated Sandbox Output)

Pass an isolated `IFOCUS_SBX_OUT` directory per reviewer so parallel runs never collide on module caches or binaries:

```bash
IFOCUS_SBX_OUT="/tmp/ifocus-cr-$(id -u)" ./scripts/sbx.sh test
# or for security reviewer:
IFOCUS_SBX_OUT="/tmp/ifocus-sr-$(id -u)" ./scripts/sbx.sh test
```

Default paths in `scripts/sbx.sh` and `scripts/bundle-app.sh` resolve to per-user `0700` non-symlink directories (`/tmp/ifocus-sbx-$(id -u)` and `/tmp/ifocus-build-$(id -u)`).

## Verification Gates (`G1b`, `G2`–`G7`)

### G1b — SwiftPM Package Manifest Validation (PASSED)

Command:
```bash
TMPDIR=/tmp CLANG_MODULE_CACHE_PATH="/tmp/clang-cache-$(id -u)" SWIFTPM_MODULECACHE_OVERRIDE="/tmp/swiftpm-cache-$(id -u)" \
  swift package --disable-sandbox --scratch-path "/tmp/ifocus-build-$(id -u)" describe
```

Result (`exit 0`, tail):
```text
G1b PASS
    Target dependencies:
        iFocusCore
        iFocusMac
    Product memberships:
        ifocus

Swift languages versions:
    6
```

### G2 — Direct `swiftc` Build & 78-Test Suite (PASSED)

Command:
```bash
IFOCUS_SBX_OUT="/tmp/ifocus-sbx-$(id -u)" ./scripts/sbx.sh test
```

Result (`exit 0`, 0 compiler `warning:` lines, tail):
```text
✔ Suite "Coordinator" passed after 0.205 seconds.
✔ Test "T35 deskThree 60s session across 10 seeds" passed after 0.483 seconds.
✔ Test "T08 noisy calibration across 20 seeds" passed after 0.654 seconds.
✔ Suite "Calibration" passed after 0.654 seconds.
✔ Test "T73 ScenarioRunner.runWithLadder matches sync runner and expected switches across scenarios and seeds" passed after 0.811 seconds.
✔ Suite "Scenario" passed after 0.856 seconds.
✔ Test run with 78 tests in 17 suites passed after 0.856 seconds.
G2 warnings: 0
```

### G3 — Static Invariants (PASSED)

Command:
```bash
./scripts/check-invariants.sh
```

Result (`exit 0`):
```text
All invariants passed.
```

### G4 — End-to-End CLI Simulation (PASSED)

Command:
```bash
/tmp/ifocus-sbx-$(id -u)/ifocus --simulate all
```

Result (`exit 0`, tail):
```text
Scenario 'dual-external-mismatch' (seed=1): PASS
  Expected switches: [204]
  Actual switches:   [204]
  [t=  2.35s] focus -> window 204
  [t=  0.30s] mismatch alert: focused=201 gazed=204
  [t=  2.30s] mismatch alert: focused=201 gazed=204
Scenario 'dual-external-flyover' (seed=1): PASS
  Expected switches: [204]
  Actual switches:   [204]
  [t=  0.95s] focus -> window 204
```

### G5 — Plist Lint, Release Bundle & Code Signing (PASSED)

Command:
```bash
plutil -lint Resources/Info.plist && IFOCUS_SBX_OUT="/tmp/ifocus-sbx-$(id -u)" ./scripts/bundle-app.sh
```

Result (`exit 0`):
```text
Resources/Info.plist: OK
dist/iFocus.app: replacing existing signature
Bundled and signed dist/iFocus.app
```

### G6 — Script Hardening Verification (PASSED)

Command:
```bash
./scripts/check-scripts.sh
```

Result (`exit 0`):
```text
Script hardening checks passed.
```

### G7 — CLI Control Flags & Headless Diagnostics (PASSED, < 1 s)

Commands:
```bash
/tmp/ifocus-sbx-$(id -u)/ifocus --help
/tmp/ifocus-sbx-$(id -u)/ifocus --version
/tmp/ifocus-sbx-$(id -u)/ifocus --doctor
```

Result (`exit 0` for all three, tail):
```text
Eligible Windows (10):
  ...
  - id=6585 pid=16270 bundle=com.googlecode.iterm2 bounds=(748, 29, 746, 938) z=30 axMatch=skipped (not trusted)

Occluders & Security Prompts (2, prompt veto active: yes):
  - [securityPrompt] id=28678 pid=1290 owner=com.apple.loginwindow layer=2004 bounds=(0, 0, 1496, 967)
  - [securityPrompt] id=28677 pid=1290 owner=com.apple.loginwindow layer=2001 bounds=(-15000, -15000, 30000, 30000)
=== G7 EXIT 0 ===
```

## Triage Remediation Mapping (`TRG-01`–`TRG-28`)

| ID | Fixing Location (`file:line`) | Proving Test or Gate |
|---|---|---|
| TRG-01 | `Sources/iFocusCore/Engine/FocusCoordinator.swift:111-114, 228-286, 325-376` | `T55`, `T56` (`CoordinatorTests.swift:87, 146`) |
| TRG-02 | `Sources/iFocusCore/Engine/WatchedStream.swift:8-109`; `Sources/iFocusMac/UI/CalibrationOverlay.swift:130-183, 280, 305`; `Sources/iFocusMac/Gaze/CameraSession.swift:208-235` | `T57` (`CoordinatorTests.swift:205`); inspection + `G2` |
| TRG-03 | `Sources/iFocusCore/Model/FocusTypes.swift:34`; `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:8-52, 74-148`; `Sources/iFocusMac/Focus/AXActuator.swift:24-110, 160-162` | `T58` (`LadderTests.swift:92`); inspection + `G2` |
| TRG-04 | `Sources/iFocusCore/Model/SessionActivity.swift:3-29`; `Sources/iFocusMac/Input/SystemSessionStateProvider.swift:24-188`; `Sources/iFocusMac/App/AppController.swift:36-65, 341-372` | `T59` (`SafetyTests.swift:322`); inspection + `G2` |
| TRG-05 | `Sources/iFocusCore/Targeting/WindowClassifier.swift:4-90`; `Sources/iFocusCore/Targeting/WindowHitTester.swift:5-44`; `Sources/iFocusCore/Engine/SafetyPolicy.swift:16`; `Sources/iFocusCore/Engine/FocusDecisionEngine.swift:45-59, 165-179`; `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:62-115`; `Sources/iFocusMac/App/Doctor.swift:77-112` | `T60`, `T61`, `T62` (`HitTestTests.swift:121, 230`; `SafetyTests.swift:349`); `G7` |
| TRG-06 | `Sources/iFocusCore/Model/Config.swift:16-31`; `Sources/iFocusCore/Engine/SafetyPolicy.swift:47` | `T63` (`SafetyTests.swift:435`) |
| TRG-07 | `Sources/iFocusCore/Engine/FocusCoordinator.swift:45-80, 141, 155` | `T64` (`CoordinatorTests.swift:324`) |
| TRG-08 | `Sources/iFocusCore/Targeting/AXWindowMatcher.swift:13` | `T65` (`AXMatchTests.swift:67`) |
| TRG-09 | `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:109, 117, 150-196`; `Sources/iFocusCore/Simulation/SimServices.swift:280, 298` | `T66` (`LadderTests.swift:132`) |
| TRG-10 | `Sources/iFocusCore/Engine/FocusDecisionEngine.swift:15-185` | `T67` (`EngineTests.swift:430`) |
| TRG-11 | `Sources/iFocusCore/Model/WindowTypes.swift:74-82`; `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:141-145`; `Sources/iFocusCore/Protocols/Services.swift:40`; `Sources/iFocusMac/Focus/AXActuator.swift:119-145`; `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:108`; `Sources/iFocusCore/Simulation/SimServices.swift:365` | `T68` (`LadderTests.swift:174`); inspection + `G2` |
| TRG-12 | `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:19-115` (`bundleIDCache` deleted) | Inspection (`0` grep hits for `bundleIDCache` in `Sources/`) + `G2`, `G7` |
| TRG-13 | `Sources/iFocusCore/Engine/FocusCoordinator.swift:82-87, 118-126, 219-226, 480-555`; `Sources/iFocusMac/UI/StatusMenuController.swift:115-125` | `T69` (`CoordinatorTests.swift:376`); inspection + `G2` |
| TRG-14 | `Sources/iFocusCore/Engine/FocusCoordinator.swift:89-94, 142, 280-324` | `T70` (`CoordinatorTests.swift:428`) |
| TRG-15 | `Sources/iFocusMac/Gaze/CameraSession.swift:125-127, 199, 255-268`; `Sources/iFocusMac/Gaze/VisionGazeEstimator.swift:46-80` | Inspection + `G2` |
| TRG-16 | `Sources/iFocusApp/IFocusCLI.swift:14, 33, 57` | `G4`, `G7` (`--doctor` completes in < 1 s) |
| TRG-17 | `scripts/sbx.sh:5-21`; `scripts/bundle-app.sh:5-48`; `scripts/check-scripts.sh:1-38`; `README.md:31-34` | `G5`, `G6` |
| TRG-18 | `Sources/iFocusCore/Storage/SecureFileStore.swift:57-260` | `T34`, `T71` (`FileStoreTests.swift:7, 72`) |
| TRG-19 | `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:36, 80-119` | `T72` (`LadderTests.swift:203`) |
| TRG-20 | `Sources/iFocusCore/Simulation/ScenarioRunner.swift:149-225` | `T73` (`ScenarioTests.swift:130`) |
| TRG-21 | `Tests/iFocusCoreTests/EngineTests.swift:365-427` | `T51` (`EngineTests.swift:314`) |
| TRG-22 | `Sources/iFocusCore/Filter/FrameDecimator.swift:3-32`; `Sources/iFocusMac/Gaze/FrameProcessor.swift:12-23` | `T74` (`FeaturePipelineTests.swift:78`) |
| TRG-23 | `Sources/iFocusMac/Gaze/CameraSession.swift:175-196` | Inspection + `G2` |
| TRG-24 | `scripts/check-invariants.sh:70-100`; `Sources/iFocusCore/Simulation/SimServices.swift:6` | `G3` |
| TRG-25 | `Sources/iFocusCore/Filter/EyeGeometry.swift:4-134`; `Sources/iFocusMac/Gaze/FrameProcessor.swift:97`; `README.md:65, 117` | `T75` (`FeaturePipelineTests.swift:108`) |
| TRG-26 | `Sources/iFocusMac/App/AppController.swift:319-372` | Inspection + `G2` |
| TRG-27 | `Sources/iFocusCore/Targeting/WindowHitTester.swift:66-78` | `T76` (`HitTestTests.swift:276`) |
| TRG-28 | `Sources/iFocusMac/UI/HUDController.swift:84-91` | Inspection + `G2` |

## Plan B Grafts (`RB1`–`RB7`) & Arbiter Amendments (`AR1`–`AR8`)

| ID | Implementation Location (`file:line`) | Proving Test or Gate |
|---|---|---|
| RB1 | `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:10, 150-196` | `T66` (`LadderTests.swift:132`) |
| RB2 | `Sources/iFocusCore/Engine/FocusCoordinator.swift:184, 190, 205, 234` | `T69` (`CoordinatorTests.swift:376`) |
| RB3 | `Sources/iFocusMac/App/AppController.swift:252-265` | Inspection + `G2` |
| RB4 | `Sources/iFocusMac/UI/HUDController.swift:84-91` | Inspection + `G2` |
| RB5 | `scripts/sbx.sh:5-15`; `scripts/bundle-app.sh:5-15` | `G6` |
| RB6 | `Sources/iFocusMac/Focus/AXActuator.swift:133` | Inspection + `G2` |
| RB7 | `README.md:124-132` | Inspection (`README.md`) |
| AR1 | `Sources/iFocusCore/Model/Config.swift:40-46`; `Sources/iFocusCore/Targeting/WindowClassifier.swift:12-20`; `Sources/iFocusMac/Windows/CGWindowCatalogService.swift:62-75`; `Sources/iFocusMac/App/Doctor.swift:102-112` | `T60` (`HitTestTests.swift:121`), `G7` |
| AR2 | `Sources/iFocusCore/Model/Config.swift:48-54`; `Sources/iFocusCore/Targeting/WindowClassifier.swift:62-70` | `T60` (`HitTestTests.swift:121`) |
| AR3 | `Sources/iFocusCore/Engine/FocusCoordinator.swift:505-511`; `Sources/iFocusCore/Model/FocusTypes.swift:230-245`; `Sources/iFocusMac/UI/StatusMenuController.swift:115-120` | `T77` (`CoordinatorTests.swift:535`) |
| AR4 | `Sources/iFocusCore/Model/Config.swift:22-23` | `T63` (`SafetyTests.swift:435`) |
| AR5 | `Sources/iFocusCore/Engine/FocusCoordinator.swift:288-298` | `T78` (`CoordinatorTests.swift:600`) |
| AR6 | `Sources/iFocusCore/Model/FocusTypes.swift:16-21`; `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:80-116`; `Sources/iFocusMac/Focus/AXActuator.swift:99-109` | `T72` (`LadderTests.swift:203`) |
| AR7 | `Tests/iFocusCoreTests/` (`CoordinatorTests.swift`, `HitTestTests.swift`, `LadderTests.swift`, `SafetyTests.swift`, `AXMatchTests.swift`, `FileStoreTests.swift`, `ScenarioTests.swift`, `FeaturePipelineTests.swift`, `EngineTests.swift`) | `G2` (78 tests pass) |
| AR8 | `Tests/iFocusCoreTests/CoordinatorTests.swift:87-203` (wall-clock delay only in `T55`/`T56`; virtual time everywhere else) | `G2` |
