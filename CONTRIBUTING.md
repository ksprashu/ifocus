# Contributing to iFocus

Thank you for helping improve iFocus. All code changes must preserve Swift 6 strict concurrency, deterministic simulation testability, and the architecture/security invariants below.

## Local Verification Gates

Run these gates before opening a pull request:

```bash
swift build
swift test
./scripts/sbx.sh test
./scripts/check-invariants.sh
./scripts/check-scripts.sh
```

Additional checks when changing bundling, workflows, or security-sensitive code:

```bash
./scripts/bundle-app.sh
/tmp/ifocus-sbx-$(id -u)/ifocus --simulate all
/tmp/ifocus-sbx-$(id -u)/ifocus --doctor
actionlint .github/workflows/*.yml
zizmor --offline .github/workflows/
```

## Mandatory Engineering Invariants (`I1`–`I9`)

Every pull request runs `scripts/check-invariants.sh`, enforcing:

- **I1:** No cursor warping, synthetic keyboard/mouse injection, `CGEventTap`, global event monitors, `kAXPressAction`, `kCGWindowName`, `kAXTitleAttribute`, or deprecated `activateAllWindows`/`activateIgnoringOtherApps` in `Sources/`.
- **I2:** No `import XCTest`, `.atomic` writes, or temp-dir helpers (`temporaryDirectory` / `NSTemporaryDirectory`) in `Sources/` or `Tests/`.
- **I3:** `Sources/iFocusCore/` may `import` only `Foundation` and `CoreGraphics`.
- **I4:** At most two `@unchecked Sendable` conformances (confined to `Sources/iFocusMac/Gaze/`) and exact one `nonisolated(unsafe)` (confined to lock-guarded `LockedBox` in `Sources/iFocusCore/Simulation/SimServices.swift`).
- **I5:** Private `_AXUIElementGetWindow` lookup is confined strictly to `Sources/iFocusMac/Focus/AXWindowID.swift`.
- **I6:** No `try!`, `fatalError(`, or `main.swift` in `Sources/` (`IFocusCLI` uses `@main`).
- **I7:** Every script under `scripts/*.sh` uses `set -euo pipefail` and avoids dynamic evaluation, `curl`, and privilege-escalation commands.
- **I8:** No host home paths or local file URLs in any tracked or non-ignored file; all documentation links must be repo-relative.
- **I9:** Zero networking APIs (`URLSession`, `URLRequest`, `Network`, `CFSocket`, etc.) anywhere in `Sources/`.

## Rules for Contributors

- **No external dependencies:** Keep `Package.swift` dependency-free beyond Apple system frameworks (`Foundation`, `CoreGraphics`, `AppKit`, `AVFoundation`, `Vision`, `ApplicationServices`, `Carbon`, `os`).
- **Zero Swift 6 compiler warnings:** All product modules and test targets must build cleanly under `-swift-version 6`.
- **Test ID convention (`T01`–`T93+`):** New tests in `Tests/iFocusCoreTests/` run in Swift Testing (`Testing`), use deterministic virtual time (`VirtualClock` / `VirtualSleeper`) unless proving a real concurrency race, and carry sequential `T<N>` IDs in their `@Test` names.
- **Never loosen existing tests silently:** Never relax thresholds, disable/skip tests, or edit assertions in an existing `T<N>` test without documenting an explicit behaviour-contract change in the PR and build notes.
- **Repo-relative links only:** Every Markdown link in docs, plans, reviews, and reports must be repo-relative (verified by invariant `I8`).
