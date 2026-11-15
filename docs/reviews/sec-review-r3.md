<!-- Link policy: repo-relative paths only (invariant I8 forbids host home paths and local file URLs). -->
# Round 3 (Wave 2) Security Review & Deep Scan (`sec-review-r3`)

- **Target Commit:** `778bf7dde4bff60fb23a91a7a19a41454e165646` (`main`, parent `ddc35505ba8e1402cce15f80f2448d1e87ff23f7`)
- **Prior Baselines:** [docs/reviews/triage-r1.md](docs/reviews/triage-r1.md), [docs/reviews/triage-r2.md](docs/reviews/triage-r2.md), [docs/reviews/sec-review-r2.md](docs/reviews/sec-review-r2.md)
- **JSON Findings Contract:** [docs/reviews/sec-review-r3.json](docs/reviews/sec-review-r3.json) (`findings.py validate` & `findings.py gate` both exit `0`)
- **Gate Verdict:** **PASS (`0` open blocking findings across `P0`/`P1`/`P2`/`P3`; `8/8` prior security findings remain `fixed` with zero regressions)**

---

## 1. STRIDE Threat Model for Wave 2 Changes

Wave 2 expands default targeting from 7 allowlisted terminals to universal desktop applications (`focusScope: "allApps"`), replaces typing-hold pre-charging with a `2.5 s` quiet + `1.2 s`/`1.5 s` fresh dwell state machine, introduces cross-PID AX activation ladders, and adds GitHub Actions CI/governor workflows:

- **Assets:** User keystrokes/passwords across all desktop apps (browsers, password managers, terminals, media apps), webcam frames, macOS TCC Camera & Accessibility trust, local configuration (`~/Library/Application Support/iFocus/config.json`), and GitHub Actions repository/PR secrets (`GITHUB_TOKEN`, `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`).
- **Entry Points:** Cross-process window catalog (`CGWindowListCopyWindowInfo`, `NSRunningApplication`, `kCGWindowOwnerName`), OS idle/flag counters (`CGEventSource`), `config.json` (`focusScope`, `excludedBundleIDs`), and GitHub PR/comment/push events triggering `.github/workflows/*.yml`.
- **Trust Boundaries & STRIDE Verification:**
  - *Spoofing / Elevation of Privilege (Universal `allApps` Targeting):* Unbundled processes (`bundleID == nil` or empty) fail closed (`Config.isBundleAllowed` returns `false` in [Sources/iFocusCore/Model/Config.swift](Sources/iFocusCore/Model/Config.swift#L290-L300)), unknown `focusScope` strings decode safely to `.allowlist` (`line 198`), and password managers (`1Password` v7/v8, `Apple Passwords`, `Bitwarden`, `Keychain Access`), auth agents (`SecurityAgent`, `coreautha`/`CoreAuthUI`, `UserNotificationCenter`, `CoreServicesUIAgent`, `loginwindow`), `System Settings`, `ScreenSharing`, `Spotlight`, system chrome, and `iFocus` itself (`dev.ifocus.app` + runtime `Bundle.main.bundleIdentifier`) are unconditionally blocked via `Config.isHardBlocked(_:)` and `excludeBundleIDIfNeeded(_:)`.
  - *Tampering / Injection (GitHub Actions CI & Governor):* [.github/workflows/ci.yml](.github/workflows/ci.yml) triggers only on `push` (`main`) and `pull_request` (never `pull_request_target`), sets top-level `permissions: contents: read`, pins `actions/checkout` to full 40-hex SHA `3d3c42e5aac5ba805825da76410c181273ba90b1` with `persist-credentials: false`, and interpolates zero untrusted `${{ github.event.* }}` values into `run:` scripts. [.github/workflows/pr-guardian.yml](.github/workflows/pr-guardian.yml) matches the managed SHA-256 `f895264c8c614957ab2e904d006727b9df8384f7aafd73ee0b03356cacf8ae1d`, sets top-level `permissions: {}`, gates `issue_comment` strictly to non-bot `OWNER`/`MEMBER`/`COLLABORATOR` `/ai-review` commands, and pins `ksprashu/pr-guardian` to 40-hex SHA `726d97b0d63fc2bd3bf270911c41105dced26680`.
  - *Information Disclosure (Input & Camera Privacy):* [Sources/iFocusMac/Input/SystemInputActivityProvider.swift](Sources/iFocusMac/Input/SystemInputActivityProvider.swift#L9-L55) reads only idle-time counters (`keyDown`, `keyUp`, `flagsChanged`, mouse move/down/up/drag/scroll), modifier flags (`[.maskShift, .maskControl, .maskAlternate, .maskCommand]`), mouse button state, and `IsSecureEventInputEnabled()`. Invariants `I1`, `I8`, and `I9` statically forbid event taps, window title reads, host-path leaks, and networking APIs.
  - *Denial of Service / Focus Hijack (Cross-PID Ladder & Quiet-Then-Dwell):* `.typing` and `.pointerActive` both carry `.clear` disposition ([Sources/iFocusCore/Model/FocusTypes.swift](Sources/iFocusCore/Model/FocusTypes.swift#L65-L75)), wiping `pending` and `challenger` to `0` across any input activity (`T27`, `T80`–`T82`, `T90`). Cross-PID switching in [Sources/iFocusCore/Engine/LadderFocusSwitcher.swift](Sources/iFocusCore/Engine/LadderFocusSwitcher.swift#L30-L223) requires `frontmostPID == target.pid && focusedWindowID == target.windowID` for both `.alreadyFocused` (`RC1`, `T93`) and `verifyFocused` (`+ keyWindowCheck != .differs`, `T86`–`T88`, `T92`), and executes bounded rollback (`0.35 s`) prior to `.failed(.staleCandidate)` (`TRG2-02`), `.failed(.unverified)`, and `.failed(.timedOut)`.

---

## 2. Automated Scanners & Verification Gates

| Check / Scanner | Result | Verification Details |
| :--- | :--- | :--- |
| **Isolated Test Suite (`sbx.sh test`)** | **PASS (`0` warnings)** | `IFOCUS_SBX_OUT="/tmp/ifocus-sr-$(id -u)" ./scripts/sbx.sh test` -> **93/93 tests in 17 suites passed** (`0.837 s`). |
| **Static Invariants (`check-invariants.sh`)** | **PASS** | `I1`–`I9` passed (including `I8` host-path/local-URL scrub across all tracked & untracked docs and `I9` zero networking APIs in `Sources/`). |
| **Script Hardening (`check-scripts.sh`)** | **PASS** | Symlinked `IFOCUS_SBX_OUT` rejected (`exit 1`) by both `scripts/sbx.sh` and `scripts/bundle-app.sh`. |
| **`gitleaks` (`8.30.1`)** | **CLEAN (`0` leads)** | `run_scanners.py --audit` (git history) and `gitleaks dir --redact .` (`1.25 MB` scanned) reported zero leaks. |
| **`actionlint` (`1.7.12`)** | **CLEAN (`0` leads)** | `.github/workflows/ci.yml` and `.github/workflows/pr-guardian.yml` passed with zero errors or warnings. |
| **`zizmor` (`1.31.1 --offline`)** | **CLEAN (`0` leads)** | Zero findings across `.github/workflows/` (default persona) and zero findings on `.github/workflows/ci.yml` under `--persona=auditor`. |
| **Supply Chain (`osv-scanner` / `trivy`)** | **SKIPPED (N/A)** | Zero third-party dependencies, lockfiles, containers, or IaC manifests in repository; `LICENSE` verified unmodified Apache-2.0 (`cfc7749b...`). |
| **`semgrep` (`not_inspected`)** | **ERROR (`exit 2`)** | Blocked by sandbox reading `~/.semgrep/settings.yml` and offline rule registry (settled on first connected `pr-guardian.yml` run; full manual review completed across all 46 Round 3 changed/added files). |

---

## 3. Regression Status of Prior Findings (`SEC-001`–`SEC-008` & `TRG2-02`)

- **`SEC-001` (`P1`, `CWE-807`, Lock-screen camera/AX gating):** **FIXED** (no regression; `T59`, `T78` green).
- **`SEC-002` (`P1`, `CWE-1021`, `layer > 0` modal/auth occlusion & prompt veto):** **FIXED & STRENGTHENED** (`CoreAuthUI` process-name alias added in `RC3`; Spotlight `layer > 0` occlusion verified in `T85`).
- **`SEC-003` (`P1`, `CWE-863`, Unconditional `hardBlocklist` enforcement):** **FIXED & EXPANDED** (`Config.isHardBlocked` covers password managers by exact ID and bundle prefix, `Spotlight`, `systemuiserver`, `dev.ifocus.app`, plus runtime `Bundle.main.bundleIdentifier` self-exclusion; `T63`, `T84`, `T85` green).
- **`SEC-004` (`P2`, `CWE-379`, Shared `/tmp` script hardening):** **FIXED** (`prepare_secure_dir` + UID-scoped dirs preserved alongside `AW4` CLT/Xcode probe; `G6` green).
- **`SEC-005` (`P2`, `CWE-672`, PID-wraparound `bundleIDCache`):** **FIXED** (per-snapshot local PID map preserved).
- **`SEC-006` (`P2`, `CWE-732`, `SecureFileStore` directory permissions & `dirFD` pinning):** **FIXED** (`T34`, `T71` green).
- **`SEC-007` (`P2`, `CWE-770`, Bounded `FocusCoordinator.decisionLog`):** **FIXED** (`4096`-entry `RingBuffer`; `T64` green).
- **`SEC-008` (`P3`, `CWE-636`, Calibration cancel/error `wasPaused` restoration):** **FIXED** (`AppController.swift:320, 372`).
- **`TRG2-02` (`P3`, `.staleCandidate` rollback):** **FIXED** (`LadderFocusSwitcher.swift:138` calls `rollbackIfNeeded` before returning `.failed(.staleCandidate)`, proven by `T88`).

**Conclusion:** `0` open `P0`–`P3` security findings remain. Commit `778bf7d` is approved for public GitHub repository creation and `pr-guardian` onboarding.
