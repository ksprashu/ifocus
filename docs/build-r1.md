# iFocus Build & Verification Report — Round 1

- **Plan:** `docs/plans/final-plan-r1.md`
- **Toolchain:** Apple Swift version 6.4 (`swiftlang-6.4.0.34.1 clang-2100.3.34.1`), `arm64-apple-macosx26.0`, Command Line Tools (`/Library/Developer/CommandLineTools`)
- **Tests:** **54 tests in 17 suites passed** (`T01`–`T54`, 0 failures, 0 skipped, 0 disabled)
- **Deviations from plan:** None. All 54 acceptance tests run at full thresholds with zero stubs or placeholders.
- **Git commit:** Single Round 1 commit on `main` (`Round 1: ...`, hash printed by `TMPDIR=/tmp git rev-parse HEAD` and recorded in the Round 1 handoff board post).

## Reviewer Verification Command (Isolated Sandbox Output)

Use your own `IFOCUS_SBX_OUT` directory so parallel `code-reviewer` and `sec-reviewer` runs never collide on module caches or binaries (`swift test` cannot write its XCBuild manifest inside the agent sandbox; see Gate G1 below):

```bash
IFOCUS_SBX_OUT=/tmp/ifocus-cr scripts/sbx.sh test
```

## Verification Gates

### G1 — Canonical SwiftPM (attempted once per Section 10; expected sandbox failure V2)

Command:
```bash
TMPDIR=/tmp CLANG_MODULE_CACHE_PATH=/tmp/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-cache \
  swift test --disable-sandbox --scratch-path /tmp/ifocus-build -Xswiftc -module-cache-path -Xswiftc /tmp/swift-modcache
```

Result: exited with code `1` (reproduces known sandbox V2 limitation):
```text
error: unexpected service error: build aborted due to an internal error: unable to write manifest to '/tmp/ifocus-build/out/Intermediates.noindex/XCBuildData/f8e494d96dc33f40fc71741d9225adea.xcbuilddata/manifest.json': Error Domain=NSCocoaErrorDomain Code=513 "You don’t have permission to save the file “manifest.json” in the folder “f8e494d96dc33f40fc71741d9225adea.xcbuilddata”." UserInfo={NSUnderlyingError=0xc6780e3d0 {Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"}, ...}
error: Unexpected build state
error: fatalError
```

### G1b — SwiftPM Manifest Validation (PASSED)

Command:
```bash
TMPDIR=/tmp CLANG_MODULE_CACHE_PATH=/tmp/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-cache \
  swift package --disable-sandbox --scratch-path /tmp/ifocus-build describe
```

Result (exit `0`, tail):
```text
    C99name: iFocusApp
    Module type: SwiftTarget
    Path: Sources/iFocusApp
    Sources:
        IFocusCLI.swift
    Target dependencies:
        iFocusCore
        iFocusMac
    Product memberships:
        ifocus

Swift languages versions:
    6
```

### G2 — Direct `swiftc` Build & 54-Test Suite (PASSED)

Command:
```bash
./scripts/sbx.sh test
```

Result (exit `0`, tail):
```text
✔ Suite "Coordinator" passed after 0.082 seconds.
✔ Test "T53 dualExternal scenario succeeds without window IDs" passed after 0.081 seconds.
✔ Test "T50 profile invariant validation rejects corrupted profiles" passed after 0.082 seconds.
✔ Test "T14 profile roundtrip camera mismatch and rearranged bounds" passed after 0.085 seconds.
✔ Suite "Profile" passed after 0.087 seconds.
✔ Test "T12 display selection center edge and offscreen margins" passed after 0.088 seconds.
✔ Suite "DisplaySelection" passed after 0.089 seconds.
✔ Test "T47 blink hold and eye dropout fallback" passed after 0.092 seconds.
✔ Suite "FeaturePipeline" passed after 0.093 seconds.
✔ Test "T35 deskThree 60s session across 10 seeds" passed after 0.437 seconds.
✔ Suite "Scenario" passed after 0.438 seconds.
✔ Test "T08 noisy calibration across 20 seeds" passed after 0.591 seconds.
✔ Suite "Calibration" passed after 0.592 seconds.
✔ Test run with 54 tests in 17 suites passed after 0.592 seconds.
```

### G3 — Static Invariants (PASSED)

Command:
```bash
./scripts/check-invariants.sh
```

Result (exit `0`):
```text
All invariants passed.
```

### G4 — End-to-End CLI Simulation (PASSED)

Command:
```bash
./scripts/sbx.sh build && /tmp/ifocus-sbx/ifocus --simulate all
```

Result (exit `0`, tail):
```text
Scenario 'desk-three' (seed=1): PASS
  Expected switches: [102, 103, 104, 105, 103, 101, 104]
  Actual switches:   [102, 103, 104, 105, 103, 101, 104]
Scenario 'dual-external' (seed=1): PASS
  Expected switches: [204, 202, 205, 203, 201]
  Actual switches:   [204, 202, 205, 203, 201]
Scenario 'dual-external-before-typing' (seed=1): PASS
  Expected switches: [204]
  Actual switches:   [204]
Scenario 'dual-external-mismatch' (seed=1): PASS
  Expected switches: [204]
  Actual switches:   [204]
Scenario 'dual-external-flyover' (seed=1): PASS
  Expected switches: [204]
  Actual switches:   [204]
```

### G5 — Plist Validation & App Bundle Signing (PASSED)

Command:
```bash
plutil -lint Resources/Info.plist && ./scripts/bundle-app.sh
```

Result (exit `0`):
```text
Resources/Info.plist: OK
dist/iFocus.app: replacing existing signature
Bundled and signed dist/iFocus.app
```

### Headless CLI Diagnostics Check (`--doctor`)

`dist/iFocus.app/Contents/MacOS/ifocus --doctor` exits `0` (`NSCameraUsageDescription: present`, `Window-ID resolver mode: private symbol`, `Displays: no active displays`, 10 live terminal windows enumerated without reading titles). `--doctor --focus-test` cleanly exits `77` when Accessibility is not granted, and unknown flags exit `64`.

## Not Verifiable in Sandbox

Per `docs/plans/final-plan-r1.md` Section 14, runtime Vision landmark quality (`NV1`), macOS 26 AX keyboard-focus actuation across terminal apps (`NV2`), and TCC prompt attribution under `open dist/iFocus.app` (`NV3`) require the on-desk checklist in `README.md`.
