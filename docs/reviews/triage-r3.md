<!-- Link policy: repo-relative paths only (invariant I8 forbids host home paths and local file URLs). -->
# Round 3 (Wave 2) Verification Triage (`triage-r3`)

- **Reviewed Commit:** `778bf7dde4bff60fb23a91a7a19a41454e165646` (`main`, parent `ddc35505ba8e1402cce15f80f2448d1e87ff23f7`)
- **Inputs Consolidated:**
  - `sec-reviewer` (#35): [docs/reviews/sec-review-r3.md](docs/reviews/sec-review-r3.md) + [docs/reviews/sec-review-r3.json](docs/reviews/sec-review-r3.json) (`P0: 0, P1: 0, P2: 0, P3: 0`; `8/8` prior security findings `fixed`; `TRG2-02` closed)
  - `code-reviewer` (#36): [docs/reviews/code-review-r3.md](docs/reviews/code-review-r3.md) + [docs/reviews/code-review-r3.json](docs/reviews/code-review-r3.json) (`P0: 0, P1: 0, P2: 0, P3: 4`; Wave 2 timing, `allApps` scope, cross-PID ladder, and allowed test edits verified)
- **Triage Verification Run:**
  - `IFOCUS_SBX_OUT="/tmp/ifocus-triage-$(id -u)" ./scripts/sbx.sh test`: **93/93 tests in 17 suites passed** (`0.858 s`, `0` compiler warnings).
  - `./scripts/check-invariants.sh`: **All invariants (`I1`–`I9`) passed.**
  - `./scripts/check-scripts.sh`: **Script hardening checks passed.**
  - `"/tmp/ifocus-triage-$(id -u)/ifocus" --simulate all`: **8/8 scenarios passed** (`desk-three`, `dual-external`, `dual-external-before-typing`, `dual-external-typing-then-quiet`, `dual-external-flyover`, `dual-external-type-too-soon`, `mixed-apps-tour`, `mixed-apps-typing-while-reading`).
- **Sandbox Residual Note:** `swift build` / `swift test` (proven on first GitHub Actions CI run), Xcode toolchain branch of `scripts/sbx.sh`, `semgrep` (`exit 2` offline), and live multi-app desktop AX activation remain outside sandbox coverage and are documented for CI and the on-desk checklist.

---

## (a) Summary Counts by Disposition & Severity

### Wave 2 Upgrade & Carry-Over Verification
- **Quiet-then-fresh-dwell (`2.5 s` quiet + `1.2 s`/`1.5 s` dwell):** Verified `.typing` and `.pointerActive` use `.clear` disposition (`Sources/iFocusCore/Model/FocusTypes.swift:67-69`), `SystemInputActivityProvider.swift:12-44` reads idle timers/modifier mask without taps, and mismatch alert code is cleanly retired.
- **Universal `allApps` targeting + cross-PID ladder:** Verified nil/empty bundle fail-closed, unconditional `Config.isHardBlocked(_:)` + prefix matching + runtime self-exclusion (`Config.swift:245-300`), cross-PID rung B/C (`raise` -> `bring forward` -> `raise`), 8-poll verification requiring `frontmostPID && focusedWindowID && keyWindowCheck != .differs`, and `TRG2-02` closed (`LadderFocusSwitcher.swift:138-139`).
- **GitHub readiness & supply chain:** Verified `ci.yml`, `pr-guardian.yml`, `LICENSE` (unmodified Apache-2.0), `I8`/`I9` invariants, `actionlint`, `zizmor --offline`, and `gitleaks` clean.

### Round 3 Findings Summary

| Disposition | P0 | P1 | P2 | P3 | Unscored / Roadmap | Total |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **`VALIDATED_ACTIONABLE`** *(non-blocking optional polish)* | 0 | 0 | 0 | 4 | 0 | **4** |
| **`REJECTED_FALSE_POSITIVE`** | 0 | 0 | 0 | 0 | 0 | **0** |
| **`DEFERRED_V2`** *(carried from R1/R2)* | 0 | 0 | 0 | 0 | 4 | **4** |
| **Total** | **0** | **0** | **0** | **4** | **4** | **8** |

*(Note: `TRG3-03` supersedes/re-anchors Round 2's `TRG2-01` under `allApps`; `TRG2-03` from Round 2 also remains an open non-blocking `P3` carry-over.)*

---

## (b) Validated Findings (Non-Blocking `P3` Polish Only — `0` `P0`/`P1`/`P2`)

#### `TRG3-01` (`P3` | Source: `CR3-01`) — Quiet-then-dwell timing tests check lower bounds only
- **Where:** `Tests/iFocusCoreTests/SafetyTests.swift:143-145` (`T27`), `Tests/iFocusCoreTests/ScenarioTests.swift:25` (`T35`), `53-54` (`T37`).
- **Verified Behaviour:** `T27` asserts `>= 6.25 - 1e-6` inside a `7.0 s` run, `T37` asserts `>= 5.05 - 1e-6` inside a `7.0 s` scenario, and `T35` allows `<= 2.0 s` latency against `1.20–1.55 s` measured dwell. Upper bounds are absent on `T27` and `T37`, so a `0.75–1.95 s` latency regression would still pass.
- **Acceptance Criterion (optional polish):** Add tight upper bounds (`<= 6.35` on `T27`, measured `<= 5.15 + filterLag` on `T37`, and `<= 1.60` on `T35`) without inducing seed flakiness across seeds `1...10`.

#### `TRG3-02` (`P3` | Source: `CR3-02`) — `.pointerActive` lacks the `"Waiting for input to go quiet"` status cue
- **Where:** `Sources/iFocusMac/UI/StatusMenuController.swift:112`; `Sources/iFocusMac/Input/SystemInputActivityProvider.swift:21`.
- **Verified Behaviour:** `StatusMenuController` sets `"Waiting for input to go quiet"` only when `status.lastVeto == .typing`. Under the `2.0 s` `pointerMoveLockSeconds` / `2.5 s` `pointerClickLockSeconds`, a noisy optical mouse or palm on trackpad holds `.pointerActive` while the menu state still reads `"Running"`.
- **Acceptance Criterion (optional polish):** Show `"Waiting for input to go quiet"` for both `.typing` and `.pointerActive` in `StatusMenuController.swift:112` and add a pointer-jitter troubleshooting bullet in `README.md`.

#### `TRG3-03` (`P3` | Source: `CR3-03`, updating `TRG2-01`) — All-or-nothing 0.5 s AX enumeration budget has wider exposure under `allApps`
- **Where:** `Sources/iFocusMac/Focus/AXActuator.swift:10, 31-60`.
- **Verified Behaviour:** `windows(of:)` reads 4 AX attributes per window (`AXWindowID`, frame, minimized, subrole) and returns `[]` wholesale on `0.5 s` budget exhaustion (`line 36`), triggering `.windowNotFound` + `2.0 s` backoff on multi-window browsers/editors (Chrome, VS Code) even when `_AXUIElementGetWindow` would have matched immediately.
- **Acceptance Criterion (optional polish):** Query `windowID`s first when `usePrivateWindowIDResolver == true` (skipping unnecessary geometry reads when an exact ID matches) and return partial candidates on budget exhaustion.

#### `TRG3-04` (`P3` | Source: `CR3-04`) — `allApps` matching lacks an `AXStandardWindow` subrole preference/gate
- **Where:** `Sources/iFocusCore/Targeting/WindowHitTester.swift:5-13`; `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:145-162`; `Sources/iFocusMac/Focus/AXActuator.swift:52-58`.
- **Verified Behaviour:** Any layer-0 `>= 120x80` window of an allowed bundle ID is eligible in `WindowHitTester.isEligible`, and `AXWindowCandidate.subrole` is read by `AXActuator` but unused in matching. Under `allApps`, layer-0 auxiliary/transparent helper windows can trigger activation if exposed by AX.
- **Acceptance Criterion (optional polish):** Validate real desktop app subroles via `--doctor` across Chrome/Spotify/Slack/Ghostty first (to confirm legitimate windows report `AXStandardWindow` or `nil`), then add a subrole gate/preference in `LadderFocusSwitcher` / `AXWindowMatcher` for `allApps`.

*(Carried Round 2 `P3`: `TRG2-03` in `Sources/iFocusMac/Input/SystemSessionStateProvider.swift:131-149` — ~4 Hz no-op MainActor `syncHeartbeat` dispatch on unchanged refreshes.)*

---

## (c) Rejected False Positives & Deferred v2 Roadmap Items

### Rejected False Positives (`0`)
None — all claims in `sec-review-r3` and `code-review-r3` were confirmed in source code and test runs.

### Deferred to v2 (`4` carried from Round 1 & Round 2 for `reporter`)
- **`DEF-01` (`CR-11`, R1):** Configurable post-typing-pause re-dwell option (`freshDwellAfterTypingLock`). *(Note: Wave 2's quiet-then-dwell change already resolves the pre-charge concern directly; keep note only for optional post-switch UX polish.)*
- **`DEF-02` (`CR-24a`, R1):** Public-mode native-tab disambiguation when `AXWindows` exposes hidden native tabs sharing identical frames.
- **`DEF-03` (`CR2-01`, R2):** Trace-tuned majority-share dwell commit rule under severe (`>= 1-in-3`) shared-edge neighbour noise.
- **`DEF-04` (`CR2-05`, R2):** Visible sub-rect occlusion for Dock strip and Notification Center banners (`Config.chromeBundleIDs`).

---

## (d) Explicit Loop Recommendation

**`CONVERGED_READY_FOR_REPORT`**

**Basis:** `0` open `P0`, `0` open `P1`, and `0` open `P2` findings across `sec-review-r3` (#35) and `code-review-r3` (#36); `93/93` tests (`T01`–`T93`), `check-invariants.sh` (`I1`–`I9`), `check-scripts.sh`, and `8/8` simulations pass cleanly with `0` warnings. Only `4` non-blocking `P3` polish items (`TRG3-01`..`TRG3-04`, plus `TRG2-03`) and `4` v2 roadmap items remain; per coordinator dispatch #29, Round 4 is not needed and the loop converges to `reporter` to update the final report / release readiness summary.
