<!-- Link policy: repo-relative paths only (invariant I8 forbids host home paths and local file URLs). -->
# Convergence Summary (`loop-summary`)

- **Convergence Status:** **CONVERGED**
  - **Wave 1 (v1 Core):** Converged after **2 rounds** (`fb078be` -> `ddc3550`, `MAX_ROUNDS = 3`)
  - **Wave 2 (Quiet-Then-Dwell, Universal `allApps`, GitHub Readiness):** Converged after **Round 3** (`778bf7dde4bff60fb23a91a7a19a41454e165646`, `MAX_ROUNDS = 5`, `#29`)
- **Final Verification Gates (observed in `triage-r3` #37 / `builder` #34 / `sec-reviewer` #35 / `code-reviewer` #36):**
  - `IFOCUS_SBX_OUT="/tmp/ifocus-triage-$(id -u)" ./scripts/sbx.sh test`: **93/93 tests in 17 suites passed** (`0.858 s`, `0` compiler warnings; `T01`–`T93`)
  - `./scripts/check-invariants.sh`: **All invariants (`I1`–`I9`) passed**
  - `./scripts/check-scripts.sh`: **Script hardening checks passed**
  - `"/tmp/ifocus-triage-$(id -u)/ifocus" --simulate all`: **8/8 scenarios passed**
  - `actionlint`, `zizmor --offline` (default + auditor), `gitleaks`, and `trivy`: `0` leads (`semgrep` `not_inspected` offline inside sandbox; covered by manual review and CI workflow)

---

## 1. Multi-Wave Progression (`Round 1 -> Round 2 -> Round 3`)

| Metric | Round 1 (`fb078be`, `triage-r1.md`) | Round 2 (`ddc3550`, `triage-r2.md`) | Round 3 / Wave 2 (`778bf7d`, `triage-r3.md`) |
| :--- | :---: | :---: | :---: |
| **`VALIDATED_ACTIONABLE` `P0`** | 0 | **0** | **0** |
| **`VALIDATED_ACTIONABLE` `P1`** | 6 (`TRG-01`..`TRG-06`) | **0** | **0** |
| **`VALIDATED_ACTIONABLE` `P2`** | 12 (`TRG-07`..`TRG-18`) | **0** | **0** |
| **`VALIDATED_ACTIONABLE` `P3`** | 10 (`TRG-19`..`TRG-28`) | 3 (`TRG2-01`..`TRG2-03`) | **4 new** (`TRG3-01`..`TRG3-04`) + `TRG2-03` |
| **`REJECTED_FALSE_POSITIVE`** | 0 | **0** | **0** |
| **`DEFERRED_V2`** | 2 (`DEF-01`, `DEF-02`) | 4 (`DEF-01`..`DEF-04`) | **4 carried** (`DEF-01`..`DEF-04`) |
| **Test Suite** | 54/54 tests (17 suites) | 78/78 tests (17 suites) | **93/93 tests (17 suites)** |

---

## 2. Closed Findings & Wave 2 Upgrades

- **Wave 1 (`28 / 28` Closed in `ddc3550`):** All `6` `P1` (`TRG-01`..`TRG-06`), `12` `P2` (`TRG-07`..`TRG-18`), and `10` `P3` (`TRG-19`..`TRG-28`) findings closed and verified intact in `778bf7d`.
- **Wave 2 Closed Carry-Over:** `TRG2-02` (`LadderFocusSwitcher` `.staleCandidate` rollback skip) closed in `Sources/iFocusCore/Engine/LadderFocusSwitcher.swift:138-139`.
- **Wave 2 Upgrades Verified in `778bf7d`:**
  1. **Activity-Quiet + Fresh Dwell (`2.5 s` quiet + `1.2 s` / `1.5 s` dwell):** `.typing` and `.pointerActive` use `.clear` disposition (`Sources/iFocusCore/Model/FocusTypes.swift:67-69`), `SystemInputActivityProvider.swift:12-44` reads idle timers/modifier mask without event taps, and legacy typing-hold mismatch alert code is retired.
  2. **Universal `allApps` Targeting + Cross-PID Ladder:** Nil/empty bundle IDs fail closed; `Config.isHardBlocked(_:)` + prefix matching + runtime self-exclusion (`Config.swift:245-300`) block auth/password-manager/lock/chrome/self targets; cross-PID switches start at Rung B/C (`raise` -> `bring forward` -> `raise`) with `8`-poll verification requiring `frontmostPID && focusedWindowID && keyWindowCheck != .differs`.
  3. **Public GitHub & `pr-guardian` Readiness:** `LICENSE` (Apache-2.0), `SECURITY.md`, `CONTRIBUTING.md`, `DESIGN.md`, SHA-pinned `.github/workflows/ci.yml`, byte-exact `.github/workflows/pr-guardian.yml`, `README.md`, `docs/FINAL_REPORT.md`, and invariant `I8`/`I9` enforcement.

---

## 3. Remaining Non-Blocking Items & v2 Roadmap

### Remaining `P0` / `P1` / `P2` Items
- **None (`0` open `P0`, `0` open `P1`, `0` open `P2`).**

### Remaining Optional `P3` Polish Items (`5`)
1. **`TRG3-01` (`CR3-01`):** Add tight upper bounds on quiet-then-dwell timing tests (`T27`, `T35`, `T37`).
2. **`TRG3-02` (`CR3-02`):** Show `"Waiting for input to go quiet"` for `.pointerActive` in `Sources/iFocusMac/UI/StatusMenuController.swift:112` and document pointer-jitter troubleshooting in `README.md`.
3. **`TRG3-03` (`CR3-03`, updating `TRG2-01`):** Query `windowID`s first when `usePrivateWindowIDResolver == true` and return partial candidates on `0.5 s` AX enumeration budget exhaustion (`Sources/iFocusMac/Focus/AXActuator.swift:10, 31-60`).
4. **`TRG3-04` (`CR3-04`):** Validate desktop app subroles via `--doctor` and add an `AXStandardWindow` subrole preference/gate under `allApps`.
5. **`TRG2-03` (`CR2-04`, carried from R2):** Gate `@MainActor` `syncHeartbeat` dispatch in `Sources/iFocusMac/Input/SystemSessionStateProvider.swift:131-149` on state change or initial start.

### Deferred to v2 Roadmap (`4` carried)
1. **`DEF-01` (`CR-11`, R1):** Configurable post-typing-pause re-dwell option (`freshDwellAfterTypingLock`).
2. **`DEF-02` (`CR-24a`, R1):** Public-mode native-tab disambiguation via `AXTabs` / tab-bar filtering.
3. **`DEF-03` (`CR2-01`, R2):** Trace-tuned majority-share dwell commit rule under severe (`>= 1-in-3`) shared-edge neighbour noise.
4. **`DEF-04` (`CR2-05`, R2):** Visible sub-rect occlusion for Dock strip and Notification Center banners (`Config.chromeBundleIDs`).

### Unverified Outside Sandbox
- `swift build` / `swift test` (proven on GitHub Actions CI), Xcode toolchain branch of `scripts/sbx.sh`, offline `semgrep` (`exit 2`), and live Camera / Accessibility / unlocked multi-app AX activation (`README.md` on-desk checklist).

---

## 4. Next Step

Handing off to `@reporter` to update the final report / release readiness summary and wake `@coordinator` for GitHub repo creation, `pr-guardian` provisioning, and PR opening.
