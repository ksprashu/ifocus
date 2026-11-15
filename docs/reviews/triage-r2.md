# Round 2 Verification Triage (`triage-r2`)

- **Reviewed Commit:** `ddc35505ba8e1402cce15f80f2448d1e87ff23f7` (`main`, parent `fb078be3ba8e161701e8ca7784259caa241eaf1e`)
- **Inputs Consolidated:**
  - `sec-reviewer` (#23): `docs/reviews/sec-review-r2.md` + `docs/reviews/sec-review-r2.json` (`P0: 0, P1: 0, P2: 0, P3: 0`; `8/8` Round 1 security findings `fixed`)
  - `code-reviewer` (#24): `docs/reviews/code-review-r2.md` + `docs/reviews/code-review-r2.json` (`P0: 0, P1: 0, P2: 0, P3: 5`; all `26` Round 1 code-review items closed)
- **Triage Verification Run:**
  - `IFOCUS_SBX_OUT="/tmp/ifocus-triage-$(id -u)" ./scripts/sbx.sh test`: **78/78 tests in 17 suites passed** (`0.799 s`, `0` compiler warnings).
  - `./scripts/check-invariants.sh`: **All invariants passed.**
  - `./scripts/check-scripts.sh`: **Script hardening checks passed.**
- **Scanner & Sandbox Residual Note:** `semgrep` remains `not_inspected` inside the sandbox (`exit 2` accessing `~/.semgrep/settings.yml`), mitigated by `gitleaks` (`0` leads), `trivy` (`0` leads), `check-invariants.sh`, `check-scripts.sh`, and manual full-tree differential review. Unlocked desk checks (steps 1–11 in `README.md:110-130`) require Camera/Accessibility grants and an unlocked WindowServer session outside the sandbox.

---

## (a) Summary Counts by Disposition & Severity

### Round 1 Closure Verification (`TRG-01`–`TRG-28`)
All **`28`** validated Round 1 items (`6 P1`, `12 P2`, `10 P3`) are **CLOSED** in `ddc3550` with named tests (`T55`–`T78`), Round 1 probes `P1`–`P5` flipping to pass, and automated gates (`G1b`, `G2`–`G7`). `DEF-01` and `DEF-02` remain cleanly deferred to v2.

### Round 2 New Observations (`CR2-01`–`CR2-05`)

| Disposition | P0 | P1 | P2 | P3 | Unscored / Roadmap | Total |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **`VALIDATED_ACTIONABLE`** *(non-blocking optional polish)* | 0 | 0 | 0 | 3 | 0 | **3** |
| **`REJECTED_FALSE_POSITIVE`** | 0 | 0 | 0 | 0 | 0 | **0** |
| **`DEFERRED_V2`** | 0 | 0 | 0 | 0 | 2 | **2** |
| **Total New Round 2 Items** | **0** | **0** | **0** | **3** | **2** | **5** |

---

## (b) Validated Findings (Non-Blocking `P3` Polish Only — `0` `P0`/`P1`/`P2`)

#### `TRG2-01` (`P3` | Source: `CR2-02`) — `AXActuator.windows(of:)` discards partial list on 0.5 s budget and queries geometry unconditionally
- **Where:** `Sources/iFocusMac/Focus/AXActuator.swift:31-60`.
- **Verified Behaviour:** Each enumerated window executes up to 4 AX queries (`AXWindowID`, `readFrame`, `minimized`, `subrole`) even when `usePrivateWindowIDResolver == true`, and hitting `enumerationBudgetSeconds` (`0.5 s`) at `line 36` returns `[]` wholesale rather than returning already-collected candidates (safe now that `TRG-08` prevents fallback onto mismatched IDs).
- **Acceptance Criterion (if addressed in future polish):** When `usePrivateWindowIDResolver` is enabled, collect `windowID`s first and return partial candidates on budget exhaustion (verified by a unit/mock timing test).

#### `TRG2-02` (`P3` | Source: `CR2-03`) — `LadderFocusSwitcher.focus(_:)` skips `rollbackIfNeeded` on `.staleCandidate` exit
- **Where:** `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:113-118`.
- **Verified Behaviour:** Line 113 returns `.failed(.staleCandidate)` before line 117's `await rollbackIfNeeded(...)`. If rung A moved focus to an unintended window and failed verification, and rung B/C then returned `.staleCandidate`, focus would not roll back to `initial.focusedWindowID`.
- **Acceptance Criterion (if addressed in future polish):** Call `await rollbackIfNeeded(initial: initial, target: target, timedOut: false)` prior to returning `.failed(.staleCandidate)`, and extend `T66` with a rung-A wrong raise followed by rung-B `.staleCandidate`.

#### `TRG2-03` (`P3` | Source: `CR2-04`) — `SystemSessionStateProvider.applyActive` schedules a `@MainActor` heartbeat sync on unchanged refreshes
- **Where:** `Sources/iFocusMac/Input/SystemSessionStateProvider.swift:131-149`.
- **Verified Behaviour:** `applyActive(_:)` unconditionally enqueues `Task { @MainActor [weak self] in self?.syncHeartbeat(active: active) }` (`lines 146-148`) on every `0.25 s` TTL refresh even when `shouldPublish == false` (~4 no-op main-actor hops/sec while running).
- **Acceptance Criterion (if addressed in future polish):** Enqueue `syncHeartbeat` only when `shouldPublish == true` or on initial observation start.

---

## (c) Rejected False Positives & Deferred v2 Roadmap Items

### Rejected False Positives (`0`)
None — every code reference in `sec-review-r2` and `code-review-r2` was verified against `ddc3550`.

### Deferred to v2 (`2` new + `2` carried from Round 1 -> `4` total for `reporter`'s v2 Roadmap)
- **`DEF-01` (`CR-11`, Round 1):** Configurable post-typing-pause re-dwell (`freshDwellAfterTypingLock`) / persistent mismatch border for copy-from-reference workflows (`FocusDecisionEngine.swift:138-155`).
- **`DEF-02` (`CR-24a`, Round 1):** Public-mode native-tab disambiguation when `AXWindows` exposes hidden native tabs sharing identical frames (`AXWindowMatcher.swift:23-26`).
- **`DEF-03` (`CR2-01`, Round 2):** *Majority-share dwell commit rule under severe (>= 1-in-3) shared-edge neighbour noise* (`Sources/iFocusCore/Engine/FocusDecisionEngine.swift:242-250`). **Rationale:** Current strict rule (`if challenger != nil` hold commit) fixes the 1-in-6 edge-starvation defect (`T67`), preserves `T44` flyover safety, and fails safe (never switches wrongly on straddled edges); threshold tuning belongs in v2 with real recorded gaze traces.
- **`DEF-04` (`CR2-05`, Round 2):** *Visible sub-rect occlusion for Dock strip and Notification Center banners* (`Sources/iFocusCore/Targeting/WindowClassifier.swift:62-65`, `Sources/iFocusCore/Model/Config.swift:48-54`). **Rationale:** `Config.chromeBundleIDs` is intentionally `.ignored` in v1 because macOS `Dock`/`WindowManager` own full-display transparent layers; computing visible Dock/banner sub-rects (e.g. `NSScreen.frame` minus `visibleFrame`) is a clean v2 enhancement (or README Known Limit note).

---

## (d) Explicit Loop Recommendation

**`CONVERGED_READY_FOR_REPORT`**

**Basis:** `0` open `P0`, `0` open `P1`, and `0` open `P2` findings across both `sec-review-r2` (#23) and `code-review-r2` (#24); all `28` validated Round 1 items (`TRG-01`..`TRG-28`) are closed; `78/78` tests (`T01`–`T78`), `check-invariants.sh`, and `check-scripts.sh` pass with `0` compiler warnings. Only `3` optional non-blocking `P3` polish items (`TRG2-01`..`TRG2-03`) and `4` v2 roadmap candidates (`DEF-01`..`DEF-04`) remain for `reporter` to document alongside the on-desk checklist in `README.md`.
