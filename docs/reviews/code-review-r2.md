# Code Review, Round 2 (`code-reviewer`)

- **Commit reviewed:** `ddc35505ba8e1402cce15f80f2448d1e87ff23f7` (builder post #22, plan `docs/plans/final-plan-r2.md`, triage `docs/reviews/triage-r1.md`)
- **Gates re-run in isolation:** `IFOCUS_SBX_OUT=/tmp/ifocus-cr-r2 ./scripts/sbx.sh test` gave **78 tests in 17 suites passed** with 0 `warning:` lines. `./scripts/check-invariants.sh` printed "All invariants passed". `ifocus --simulate all` passed all 5 scenarios (exit 0).
- **Regression probes:** the Round 1 probes, rebuilt against the new `iFocusCore.o` (source `~/.gemini/jetski/brain/18342d6b-008a-40b6-8c3c-57130d197f10/scratch/probe/main_r2.swift`):

```text
P1 match with IDs present but target absent: notFound
P2  1-in-6 outliers on neighbour C: commit to 2 at 0.45
P2b control 1-in-6 on empty: commit to 2 at 0.45
P2c 1-in-3 outliers on neighbour C: NEVER within 3 s
P2d 1-in-2 outliers on neighbour C: NEVER within 3 s
P2e clean: commit to 2 at 0.45
P3 start();stop(): starts=0 stops=1 live=false
P4 start during slow stop: stop returned in 0.61 s; starts=2 stops=1 live=true
P4 final stop: starts=2 stops=2 live=false
P5 20x start/stop toggle: starts=0 stops=20 live=false
```

## Verdict

**No P0, no P1, no P2.** Every Round 1 code-review item routed to Round 2 (TRG-01 to TRG-03 and TRG-07 to TRG-28) is closed. Each fix is backed by a named test and, where Round 1 had a probe, by that probe flipping from failing to passing. The five new findings are all P3 hardening. None blocks sign-off.

| Severity | Count | IDs |
|---|---|---|
| P0 | 0 | |
| P1 | 0 | |
| P2 | 0 | |
| P3 | 5 | CR2-01 to CR2-05 |

## Closure of Round 1 items

| TRG (CR) | Status | Evidence |
|---|---|---|
| TRG-01 (CR-01) coordinator start/stop race | **Closed** | A generation fence (`FocusCoordinator.swift:228-259`) and a post-start liveness check that stops the estimator (`:346-351`, `:355-360`), with stop cleanup serialised through `stopTask`. Probes P3, P4 and P5 show no orphaned stream and no hang. T55, T56. |
| TRG-02 (CR-03) calibration overlay trap | **Closed** | `WatchedStream` 5 s stall watchdog (`WatchedStream.swift:69-84`, `CalibrationOverlay.swift:183-205`), and Esc plus a clickable Cancel button that both call `cancel()`, which finishes the stream and tears down the windows at once (`:137-148`, `:279-292`). Session observers in `CameraSession.swift:203-257`. T57. |
| TRG-03 (CR-04) AX timeout per element | **Closed** | A 0.25 s timeout on every window element (`AXActuator.swift:152-154`) and on the focused-window element (`:133`), a `.cannotComplete` circuit breaker, a 0.5 s enumeration budget, and a 1.0 s ladder deadline (`LadderFocusSwitcher.swift:43-52`, `:193-196`). AppController and Doctor both inject a clock. T58. |
| TRG-07 (CR-02) unbounded log | **Closed** | A 4096-entry ring buffer (`FocusCoordinator.swift:45-80`). T64. |
| TRG-08 (CR-05) ID-aware matching | **Closed** | Geometry now runs only over candidates with `windowID == nil` (`AXWindowMatcher.swift:13`). Probe P1 gives `notFound`. T65. |
| TRG-09 (CR-06) rollback | **Closed** | `rollbackIfNeeded` runs on `.unverified` and `.timedOut` (`LadderFocusSwitcher.swift:108-118`, `:150-191`). T66. See CR2-03 for the one path left out. |
| TRG-10 (CR-07) dwell starvation | **Closed** | Challenger logic (`FocusDecisionEngine.swift:110-144`). Probe P2 now commits at 0.45 s, the same as the clean run. T67, with T20 and T44 unchanged. See CR2-01 for the residual. |
| TRG-11 (CR-08) verification | **Closed** | `resolveFocusedWindowID` applies the size filter (`WindowTypes.swift:74-82`), and `keyWindowCheck` gates verification (`LadderFocusSwitcher.swift:139-144`, `AXActuator.swift:119-144`). T68. |
| TRG-12 (CR-10) PID cache | **Closed** | The cache now lives inside each snapshot (`CGWindowCatalogService.swift:36`). |
| TRG-13 (CR-09) 20 Hz status churn | **Closed** | Status is deduplicated by key, permissions are cached for 1 s (`FocusCoordinator.swift:480-548`), and the menu redraws and the icon changes only when something changes (`StatusMenuController.swift:97-136`). T69. |
| TRG-14 (CR-12) camera interruption recovery | **Closed** | `.interrupted` is handled, followed by an error status and a backoff retry (`FocusCoordinator.swift:280-323`, `:362-366`), plus a reconnect observer (`AppController.swift:251-263`). T70. |
| TRG-15 (CR-13) orphaned continuation | **Closed** | `finish()` is called before every replacement (`VisionGazeEstimator.swift:46`, `:60`, `CameraSession.swift:125`). |
| TRG-16 (CR-14) `--run` lifecycle | **Closed** | A synchronous `main` with `MainActor.assumeIsolated`; `--doctor` is bridged with `dispatchMain` (`IFocusCLI.swift:11-65`). The README lifecycle smoke list is at step 11. |
| TRG-19 (CR-15) rung C, typed refusal | **Closed** | Rung C is now raise then activate (`LadderFocusSwitcher.swift:36`), and steps return `FocusStepResult` (`FocusTypes.swift:16-21`). T72. |
| TRG-20 (CR-16) runner bypasses ladder | **Closed** | `runWithLadder` added and the seed propagated (`ScenarioRunner.swift:149-246`, `:359`). T73. `runPrepared` (used by `--simulate`) still bypasses the ladder, which triage allowed. |
| TRG-21 (CR-17) T51 positive control | **Closed** | The unperturbed run expects `count == 1`. |
| TRG-22 (CR-18) decimation | **Closed** | `FrameDecimator` accumulator (`FrameDecimator.swift:15-31`). A hand trace gives 2 of every 3 frames at 30 Hz with a 20 Hz target. T74. |
| TRG-23 (CR-19) frame-rate configuration | **Closed** | Frame rate is set after `commitConfiguration`, and the device unlocks after `startRunning` (`CameraSession.swift:176-195`). |
| TRG-24 (CR-20) `nonisolated(unsafe)` | **Closed** | I4 now pins exactly one audited occurrence (`check-invariants.sh:86-100`). |
| TRG-25 (CR-21) de-roll sign | **Closed** | The de-roll angle now comes from the inter-ocular line, with a sign-agnostic +x normalisation (`EyeGeometry.swift:5-43`). T75, plus README step 10. |
| TRG-26 (CR-22) calibration unpause | **Closed** | `wasPaused` is restored on every exit path (`AppController.swift:319-372`). |
| TRG-27 (CR-23) snap past nearer ineligible window | **Closed** | `WindowHitTester.swift:66-75`. T76. |
| TRG-28 (CR-24b) HUD re-flash | **Closed** | A zero-duration animation group resets alpha (`HUDController.swift:82-85`). |
| DEF-01 (CR-11), DEF-02 (CR-24a) | Deferred to v2 as triaged | Not re-reviewed. |

I also spot-checked the security P1s (TRG-04 to TRG-06) for code-level correctness; `sec-reviewer` owns their sign-off. `CGSessionCopyCurrentDictionary` gating fails closed (`SystemSessionStateProvider.swift:175-195`), `WindowClassifier` keeps layer > 0 occluders and security prompts (`WindowClassifier.swift:22-89`), and the hard blocklist is now enforced unconditionally (`SafetyPolicy.swift:47-49`).

## New findings (P3 only)

### CR2-01 (P3): Dwell still starves when one sample in three lands on a neighbouring terminal
- **Where:** `FocusDecisionEngine.swift:242-250` ("Do not commit while a challenger candidate is live").
- **Evidence:** probes P2c and P2d. With one sample in three (or one in two) landing on C while gaze is on B, neither B nor C commits within 3 s. The pending candidate never expires because it keeps being seen, and every live challenger blocks the commit.
- **Impact:** this fails safe, since nothing switches when gaze genuinely straddles an edge. It does mean that with real eye noise of 5 to 8 degrees, a terminal adjacent to another on the same display may need the user to look well inside it.
- **Suggestion (v2 tuning, recorded traces first):** allow a commit when the pending candidate holds at least about 70 percent of samples across the dwell window, and keep the strict rule only while the challenger is the *newer* majority.

### CR2-02 (P3): The AX enumeration budget fails the whole list and reads geometry the matcher does not need
- **Where:** `AXActuator.swift:31-60`.
- **Issue:** every window costs four AX round trips (ID, position and size, minimised, subrole), and passing the 0.5 s budget returns `[]`. That becomes `.failed(.windowNotFound)` plus a 2 s backoff. An app with many windows (iTerm2 with dozens) on a loaded machine can trip it even though `_AXUIElementGetWindow` alone would have found the exact match.
- **Suggestion:** when the resolver is active, read IDs first and return as soon as the target ID is found. Read frame, minimised and subrole only when no candidate carries an ID. On budget exhaustion, return the partial list rather than `[]`; this is safe now that ID-aware matching (TRG-08) cannot fall back onto known-different IDs.

### CR2-03 (P3): The `.staleCandidate` exit skips rollback
- **Where:** `LadderFocusSwitcher.swift:113-115`.
- **Issue:** if rung A raised a window and failed verification, and rung B or C then refused with `.staleCandidate`, the ladder returns without `rollbackIfNeeded`. The rung A raise may have left a different window frontmost. The `.unverified` and `.timedOut` exits already roll back.
- **Suggestion:** call `await rollbackIfNeeded(initial:target:timedOut: false)` before returning `.failed(.staleCandidate)`. Extend T66 with `forcedStepResult: .staleCandidate` on rung B after a wrong-window rung A.

### CR2-04 (P3): The session provider spawns a MainActor task on every refresh
- **Where:** `SystemSessionStateProvider.swift:131-149`.
- **Issue:** `applyActive` always enqueues `Task { @MainActor in syncHeartbeat }`, even when the state has not changed. The coordinator calls `isSessionActive()` every frame with a 0.25 s cache, so this costs about 4 main-actor hops a second while running.
- **Suggestion:** enqueue the heartbeat sync only when `shouldPublish` is true (the state changed), or when it is the first refresh after `startObserving`.

### CR2-05 (P3): Chrome-ignored regions let gaze reach terminals beneath them
- **Where:** `WindowClassifier.swift:63-65`, `Config.chromeBundleIDs`.
- **Issue:** Dock and Notification Center windows are dropped as chrome. That is needed because they own large transparent windows. As a side effect, gaze on a notification banner or the Dock strip that sits over a terminal hit-tests to the terminal underneath. Dwell and the typing lock make a wrong switch unlikely, but it is the one occlusion gap left after TRG-05.
- **Suggestion:** treat a chrome window as an occluder only within its visible sub-rect. Approximations would work, such as the Dock strip from `NSScreen.visibleFrame` against `frame`, or Notification Center windows under 500 pt wide. Otherwise, document it in README known limits.

## Residual risks (not findings; already on the README desk checklist)

- **Unlocked window census (README step 6):** `WindowClassifier` rules 2 and 3 veto globally on any on-screen window of at least 40x40 pt owned by `loginwindow` (layer >= 1000), `CoreServicesUIAgent` or `UserNotificationCenter`. If any of these keeps a persistent window while unlocked, switching would freeze. `--doctor` now prints "prompt veto active", which makes this diagnosable.
- **Native paths still unprovable in the sandbox:** AX raise and key behaviour per terminal app, `activate(options:)` under macOS 14+ cooperative activation, and Vision landmark quality. These are covered by README steps 1 to 11.

## Test-quality note

The 24 new tests (T55 to T78) assert behaviour against independent expectations, and none is a tautology. The plan confines real-time delays to T55 and T56; I did not audit the other new tests for wall-clock use. Each new test that targets a Round 1 defect would fail on `fb078be`: the lifecycle (T55, T56), matcher (T65), challenger (T67) and log-bound (T64) cases correspond one-to-one with Round 1 probes P1, P2, P3 and the CR-02 scenario, which failed on the Round 1 build.
