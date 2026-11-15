# Code Review, Round 3 (`code-reviewer`)

- **Commit reviewed:** `778bf7dde4bff60fb23a91a7a19a41454e165646` (builder post #34, plan `docs/plans/final-plan-r3.md`, dispatch board #29)
- **Gates re-run in isolation:** `IFOCUS_SBX_OUT=/tmp/ifocus-cr-r3 ./scripts/sbx.sh test` gave **93 tests in 17 suites passed**, with 0 `warning:` lines. `./scripts/check-invariants.sh` passed I1 to I9. `ifocus --simulate all` passed all 8 scenarios, including `mixed-apps-tour` and `mixed-apps-typing-while-reading`.
- **Scope of this review:** the three Wave 2 upgrades (quiet-then-dwell timing, universal window focus with a cross-PID ladder, repository readiness), plus closure of the Round 2 P3s this round absorbed. The CI, licence and supply-chain posture belong to `sec-reviewer`, so I looked only at the parts that affect build correctness.

## Verdict

**No P0, no P1, no P2. Four P3s.** The engine change is minimal and correct. Moving `.typing` to `.clear` (`FocusTypes.swift:68`) lets the existing clear path guarantee that nothing pre-charges during input, and that a fresh dwell starts from zero after the quiet period, with no new state. The cross-PID ladder matches the plan line for line. The existing-test edits stay inside the eight tests the arbiter allowed, so no assertion was loosened without a contract change behind it.

| Severity | Count | IDs |
|---|---|---|
| P0 | 0 | |
| P1 | 0 | |
| P2 | 0 | |
| P3 | 4 | CR3-01 to CR3-04 |

## Upgrade-by-upgrade verification

### 1. Quiet-then-fresh-dwell timing

| Check | Result | Evidence |
|---|---|---|
| No pre-charge during input | Correct | `.typing` now has disposition `.clear` (`FocusTypes.swift:68`). The engine's clear branch drops both `pending` and `challenger` and returns `dwellProgress: 0` (`FocusDecisionEngine.swift`, clear case). T27 now asserts `candidateWindowID == nil` and `dwellProgress == 0` on every locked step, a stronger assertion than before. |
| Modifier held counts as typing | Correct | `SafetyPolicy.swift:66`. Only shift, control, option and command are watched; caps lock and fn are excluded (`SystemInputActivityProvider.swift`, `watchedModifiers`), as AW3 requires. |
| Input classes (key-up into keyboard; mouse-up, drag and scroll into click; move alone) | Correct | `SystemInputActivityProvider.swift:12-40`. It still reads elapsed-time counters and state flags only. There is no tap and no key codes. |
| Defaults and ranges | Correct | `Config.swift` init and `clamped()`: 1.2 / 1.5 / 2.5 / 2.0 / 2.5, with the ranges widened to 5.0 and 10.0. T33 checks the new 5.0 clamp. |
| Mismatch alert retired cleanly | Correct | Engine branch, `EngineAction`, `CoordinatorEvent`, HUD amber flash, CLI print and `ScenarioResult.mismatchAlerts` are all removed. Legacy config keys are ignored when decoding (README line 76). `.cooldown` stays `.hold`, which is harmless now that cooldown (0.6 s) is shorter than any dwell. |
| Status cue | Correct | "Waiting for input to go quiet" appears for `.typing` (`StatusMenuController.swift:112`). See CR3-02 for `.pointerActive`. |

### 2. Universal window focus and the cross-PID ladder

| Check | Result | Evidence |
|---|---|---|
| `allApps` eligibility rule | Correct | `Config.isBundleAllowed` (`Config.swift:290-300`) fails closed on a nil or empty bundle, then applies the hard blocklist and its prefixes, then the exclusions, then the scope. It is still the single rule used by the hit-tester, the most-recently-used logic and `requireAllowedSource`. An unknown `focusScope` falls back to the narrower `.allowlist` (`:198`). |
| Frontmost blocklist uses the prefixes | Correct | `SafetyPolicy.swift:47` now calls `Config.isHardBlocked`. |
| Self-exclusion | Correct | `excludeBundleIDIfNeeded(Bundle.main.bundleIdentifier)` runs in both `AppController.init` and `Doctor.run`. It is a no-op when the ID is already hard-blocked (`dev.ifocus.app`). |
| Cross-PID starts at rung B; raise, bring forward, raise | Correct | `LadderFocusSwitcher.swift:34-45`. Same-PID still takes rungs A, B, C with 3 polls; cross-PID gets 8 polls (AW1). |
| Verification needs frontmost PID, focused window and key window | Correct | The `verifyFocused` poll requires `frontmostPID == target.pid && focusedWindowID == target.windowID && keyWindowCheck != .differs`. |
| One re-match per step on `.staleCandidate` | Correct | `LadderFocusSwitcher.swift:79-104`. Deadline checks sit around each extra AX call, and the fresh candidate is the one carried into verification. |
| RC1 `.alreadyFocused` also requires the frontmost PID | Correct | T93. |
| CR2-03 / TRG2-02: rollback before `.staleCandidate` | **Closed** | `LadderFocusSwitcher.swift:138-139`. Rollback now runs before both the stale and unverified exits. |

### 3. Repository readiness (build-correctness view only)

- `sbx.sh` now probes for its toolchain instead of exiting 2 off the Command Line Tools layout, and it still never calls `xcrun` on the Command Line Tools branch. That keeps the sandbox path clean. The Xcode candidate paths are plausible, but only CI exercises them, which the plan records as not verified.
- I8 (host paths, local file URLs) and I9 (networking APIs) are enforced. This report is written to pass I8.
- Whether `swift build` and `swift test` accept the code on the `macos-15` runner's compiler is unknowable offline, and the plan says so. The first CI run is the proof.

### Existing-test edits audited against the plan's allowance

| Test | Edit | Within allowance? |
|---|---|---|
| T16, T19, T22, T25, T39, T43, T51, T62, T67, T70, T76 and others | One-token fixture swap `Config()` to `Config.v1Mechanics` | Yes (D2). The fixture is in `TestDoubles.swift` and changes only the five timings and the scope. |
| T26 | `.typing: .clear`; source-blocked fixture moved from Safari to System Settings | Yes (Safari is now a valid source under `allApps`). |
| T27, T33, T35, T36, T37 | Re-timed or rewritten to the new contract | Yes. See CR3-01 on how tight the bounds are. |
| T58, T72 | Perform-call counts 5 to 6, with the third step a re-raise | Yes (cross-PID rung C is now raise, activate, raise). |
| T38 | Scenario renamed | Yes (rename only). |

No other test from T01 to T78 had an assertion edited.

## New findings (P3 only)

### CR3-01 (P3): The new timing assertions have lower bounds only, so slower switching would pass
- **Where:** `Tests/iFocusCoreTests/SafetyTests.swift:143-145` (T27: `>= 6.25`, inside a 7.0 s run), `Tests/iFocusCoreTests/ScenarioTests.swift:53-54` (T37: `>= 5.05`, inside a 7.0 s scenario), `ScenarioTests.swift:25` (T35 latency bound widened from 1.0 s to 2.0 s, although the plan measured 1.20 to 1.55 s).
- **Issue:** these tests prove that nothing switches *too early*. They do not prove that the switch happens *on time*. A regression that added up to 0.75 s (T27) or 1.95 s (T37) of extra latency, such as a second dwell or a dwell restarted by an off-by-one sample, would still pass. The headline user promise ("2.5 s quiet plus 1.2 s gaze, about 3.7 s total") would then be untested.
- **Fix:** add upper bounds of the expected value plus two frames: T27 `<= 6.35`, T37 `<= 5.15 + filter lag` (measure it once and pin it). Tighten T35 to `<= 1.6` to match the measured 1.20 to 1.55 s.

### CR3-02 (P3): Pointer activity gets no "waiting" cue; a noisy pointing device can stall switching silently
- **Where:** `StatusMenuController.swift:112` labels only `.typing`. `SystemInputActivityProvider.swift:21` treats any `mouseMoved` event as activity.
- **Issue:** the move-class quiet period is now 2.0 s (it was 0.8 s). `secondsSinceLastEventType` carries no distance, so a jittery optical mouse, a palm resting on the trackpad or a bumped desk keeps `.pointerActive` asserted, and switching never happens. The menu then says "Running" with "Last veto: pointerActive". That is technically accurate but not the plain cue AW9 gives for typing. `--doctor`'s live sample does make it diagnosable.
- **Fix:** use "Waiting for input to go quiet" for `.pointerActive` as well (it is the same quiet-period mechanism), and mention pointer jitter in the README troubleshooting section next to `pointerMoveLockSeconds`.

### CR3-03 (P3): TRG2-01 (the all-or-nothing AX enumeration budget) matters more under `allApps`
- **Where:** `AXActuator.swift:10`, `:31-60` (unchanged this round; TRG2-01 was explicitly out of scope).
- **Issue:** browsers and editors are now default targets. A Chrome or VS Code process with many windows costs 5 AX round trips per window (window ID, position, size, minimised, subrole). On a loaded machine, passing 0.5 s returns `[]`, which becomes `.windowNotFound` plus a 2 s backoff, even though `_AXUIElementGetWindow` alone would have found an exact match on the first pass. In Round 2 this exposure was limited to terminals.
- **Fix:** schedule TRG2-01 next. When the resolver is active, read IDs first and stop as soon as the target ID is found. Read geometry only for candidates without an ID. Return a partial list on budget exhaustion; that is safe because of TRG-08's ID-aware matcher.

### CR3-04 (P3): The `allApps` hit-test has no AX "standard window" gate before activating an app
- **Where:** `WindowHitTester.isEligible` (layer 0, at least 120x80 pt, `isBundleAllowed`). `AXWindowCandidate.subrole` is already read but not used.
- **Issue:** under `allApps`, any identified layer-0 window of at least 120x80 pt becomes a target. That includes helper or transparent windows some apps keep on screen at layer 0 (overlay utilities, tab-drag ghosts, auxiliary panels). If AX does not list such a window, the attempt fails with `.windowNotFound` and a 2 s backoff, which the plan documents as a known limit. If AX does list it with a non-standard subrole, iFocus activates that app and gives keyboard focus to a window the user may not perceive as a window.
- **Fix:** in the ladder's match step, prefer candidates whose `subrole` is `AXStandardWindow` (or nil, for apps that do not report one). Treat other subroles as `.notFound` under `allApps` unless the bundle is allowlisted. Desk step: run `--doctor` with the usual apps open and confirm that every `eligible=yes` row is a window the user recognises.

## Round 2 P3 carry-over

| Item | Status |
|---|---|
| CR2-03 / TRG2-02 `.staleCandidate` skipped rollback | Closed this round (`LadderFocusSwitcher.swift:138-139`) |
| CR2-02 / TRG2-01 AX enumeration budget | Open, out of scope; exposure raised by `allApps` (CR3-03) |
| CR2-04 / TRG2-03 MainActor heartbeat task about 4 Hz | Open, out of scope; unchanged |
| CR2-01 / DEF-03, CR2-05 / DEF-04 | Deferred to v2 as triaged |

## Residual risks (not findings)

- **Product trade-off, pinned by T91:** if the user looks at a window and starts typing within about 1.2 s, the keys go to the old window. The README and DESIGN state this. The switch flash is the only cue.
- **Not provable in the sandbox, as the plan records:** live cross-app activation and its latency, the 8-poll window being enough (AW1, desk step 16), the runner's compiler, and the Xcode branch of `sbx.sh`.
- **Blocklist coverage for other system authentication agents** (for example passkey and smart-card sheets) is a security-surface question for `sec-reviewer`. `--doctor` now prints every on-screen window with its eligibility and reason, which makes a census practical on the desk.
