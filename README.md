# iFocus

**iFocus** is a local, privacy-preserving macOS menu-bar utility that moves keyboard focus to whichever desktop window you are looking at (browsers, editors, music players, terminals), using your webcam and Accessibility APIs.

## What iFocus Does and Never Does

- **Does:** Estimates head pose and de-rolled pupil offset in memory at up to 30 fps using AVFoundation and Apple Vision, maps gaze per display via ridge regression into normalised panel coordinates, enforces a **2.5 s** zero-input quiet period (clearing pending dwell on any typing, modifier-held, click, drag, or scroll activity) before counting a fresh **1.2 s** (cross-display) / **1.5 s** (same-display) continuous dwell, targets standard desktop app windows by default (`focusScope: "allApps"`), and switches focus via a verified `CGWindowID`-aware AX ladder across same-PID and cross-PID apps.
- **Never does:** Never warps or moves the mouse cursor, never posts synthetic keyboard or mouse events, never installs a `CGEventTap` or global event monitor, never requests Screen Recording or Input Monitoring permissions, never reads window titles (`kCGWindowName` / `kAXTitleAttribute`), and never writes camera frames, crops, or feature vectors to disk or network.

See [DESIGN.md](DESIGN.md) for the full architecture, 9-rule classifier, 14-veto safety policy, focus ladder, and threat model, [SECURITY.md](SECURITY.md) for vulnerability reporting, and [CONTRIBUTING.md](CONTRIBUTING.md) for contributor guidelines and invariants `I1`–`I9`.

## Requirements

- macOS 14.0+ (Sonoma or newer)
- Swift 6 toolchain (Xcode 16+ or Command Line Tools for Xcode)
- Permissions: **Camera** and **Accessibility** only

## Building and Testing

### Canonical SwiftPM Build

```bash
swift build
swift test
```

### Direct `swiftc` Build & Verification Scripts

`scripts/sbx.sh` automatically probes both Command Line Tools and Xcode layouts (`xcode-select -p`):

```bash
./scripts/sbx.sh build
./scripts/sbx.sh test
./scripts/check-invariants.sh
./scripts/check-scripts.sh
```

By default `scripts/sbx.sh` uses `/tmp/ifocus-sbx-$(id -u)` (`0700`, non-symlink) and `scripts/bundle-app.sh --swiftpm` uses `/tmp/ifocus-build-$(id -u)` and per-user `/tmp/*-cache-$(id -u)` directories. Set `IFOCUS_SBX_OUT=/tmp/your-out-dir` to isolate build products when running concurrently.

## Bundling, Signing, and Launching

Build an optimised `.app` bundle and sign it:

```bash
./scripts/bundle-app.sh            # builds with scripts/sbx.sh (-O)
# or: ./scripts/bundle-app.sh --swiftpm
```

Launch the app bundle (recommended so macOS TCC attributes Camera and Accessibility permissions to **iFocus** rather than your terminal app):

```bash
open dist/iFocus.app
```

> **Ad-hoc signing note:** By default `bundle-app.sh` signs with `-` (ad-hoc identity). Because ad-hoc signatures produce a new CDHash on each rebuild, macOS requires you to toggle Accessibility off and back on in **System Settings -> Privacy & Security -> Accessibility** after rebuilding. Pass `IFOCUS_SIGN_IDENTITY="Developer ID Application: ..."` (or a local self-signed code-signing certificate) to preserve the Accessibility grant across rebuilds.

## CLI Modes

```text
ifocus [--run]
ifocus --calibrate
ifocus --doctor [--focus-test]
ifocus --simulate [desk-three|dual-external|mixed-apps|all] [--seed N] [--verbose]
ifocus --version
ifocus --help
```

- `--run` (default): Starts the `LSUIElement` menu-bar agent (`NSApplication.setActivationPolicy(.accessory)`).
- `--calibrate`: Launches the full-screen per-display calibration wizard (natural pass + eyes-only pass), prints leave-one-target-out cross-validation RMS error per display, writes `calibration.json`, and exits. **Upgrading note:** If upgrading from an early build without geometric contour de-roll, run `--calibrate` (or recalibrate from the menu).
- `--doctor`: Read-only diagnostics reporting permissions, `NSCameraUsageDescription` presence, window-ID resolver mode, Secure Input state, live input-activity sample, displays, cameras, `focusScope` + window eligibility with reasons, retained occluders/security prompts, and config/calibration validity. Never triggers permission prompts.
- `--doctor --focus-test`: Cycles focus across up to 6 eligible windows (preferring distinct PIDs), prints the ladder strategy (`rungA`, `rungB`, `rungC`, or `alreadyFocused`) and verification result, and restores original focus.
- `--simulate`: Runs deterministic virtual-time simulations (`desk-three`, `dual-external`, `mixed-apps`, or `all`) using 3D physical rigs and a synthetic user forward model through the real `FocusPipeline` and `LadderFocusSwitcher`.

## Configuration (`~/Library/Application Support/iFocus/config.json`)

Missing keys take defaults, out-of-range numeric values are clamped on load, and unknown keys (including legacy `mismatchAlert` keys) are ignored. Malformed JSON falls back to defaults without modifying the file on disk.

> **Upgrading to Wave 2 note:** Missing `focusScope` defaults to `"allApps"` (so existing `config.json` files without `"focusScope"` enable universal window switching while continuing to block auth dialogs, password managers, System Settings, Spotlight, system chrome, and iFocus). Add `"focusScope": "allowlist"` to restrict switching strictly to `allowedBundleIDs`, or list apps in `excludedBundleIDs` to opt individual apps out.

| Key | Default | Range | Purpose |
|---|---|---|---|
| `dwellCrossDisplaySeconds` | `1.2` | `0.15` to `5.0` | Fresh dwell when candidate is on a different display from focused window. |
| `dwellSameDisplaySeconds` | `1.5` | `0.15` to `5.0` | Fresh dwell between windows on the same display. |
| `stickyMarginPoints` | `48` | `0` to `200` | Gaze must leave focused window bounds inflated by this margin before a neighbour becomes a candidate. |
| `snapRadiusPoints` | `80` | `0` to `300` | Gaze just outside an eligible uncovered window snaps to that window. |
| `candidateDropoutSeconds` | `0.12` | `0.03` to `0.5` | Candidate survives this long without a supporting sample. |
| `switchCooldownSeconds` | `0.60` | `0.2` to `5.0` | Minimum gap between successful switches. |
| `failureBackoffSeconds` | `2.0` | `0.5` to `30` | Backoff duration after a failed switch attempt. |
| `typingLockSeconds` | `2.5` | `0.3` to `10.0` | Quiet period after key-down, key-up, or modifier change; held modifiers (`Shift`/`Control`/`Option`/`Command`) also hold and clear candidates. |
| `pointerMoveLockSeconds` | `2.0` | `0` to `10.0` | Quiet period after pointer movement (`mouseMoved`). |
| `pointerClickLockSeconds` | `2.5` | `0` to `10.0` | Quiet period after mouse down/up, drag, or scroll wheel; mouse buttons held also clear candidates. |
| `minConfidence` | `0.50` | `0.1` to `0.95` | Minimum Vision face detection confidence. |
| `staleSampleSeconds` | `0.30` | `0.1` to `1.0` | Ignore gaze samples older than this threshold. |
| `eyeHoldSeconds` | `0.30` | `0` to `1.0` | Hold eye offset through a blink before falling back to head-only model. |
| `offscreenMarginMM` | `60` | `10` to `200` | Tolerance outside a panel at the sides and top. |
| `offscreenMarginBottomMM` | `20` | `0` to `200` | Tolerance below a panel before classifying gaze as off-screen. |
| `lookDownGuard` | `true` | `bool` | Veto when head pitch exceeds `pitchDownLimit + lookDownMarginRadians`. |
| `lookDownMarginRadians` | `0.14` | `0.03` to `0.6` | Pitch margin below lowest calibrated target. |
| `focusScope` | `"allApps"` | `"allApps"` or `"allowlist"` | Target all standard layer-0 apps (`allApps`) or only `allowedBundleIDs` (`allowlist`; unknown strings safely load as `allowlist`). |
| `allowedBundleIDs` | Terminal, iTerm2, Ghostty, Kitty, Alacritty, WezTerm, Warp | Max 64 valid IDs (`^[A-Za-z0-9._-]{1,255}$`) | Eligible apps when `focusScope` is `"allowlist"`. |
| `excludedBundleIDs` | `[]` | Max 64 valid IDs (`^[A-Za-z0-9._-]{1,255}$`) | Excluded bundle IDs in both `"allApps"` and `"allowlist"` modes. |
| `requireAllowedSource` | `true` | `bool` | Only switch away when frontmost app is eligible under the active `focusScope`. |
| `respectSecureInput` | `true` | `bool` | Freeze switching while Secure Keyboard Entry is active (including terminal/browser password prompts). |
| `displayFallback` | `false` | `bool` | When `true`, gaze on empty desktop on another display targets that display's MRU eligible window. |
| `switchFlash` | `true` | `bool` | Flash accent border on newly focused window. |
| `cameraFPS` | `20` | `5` to `30` | Vision processing frame rate (enforced by decimation). |
| `cameraUniqueID` | `null` | `string?` | Explicit `AVCaptureDevice.uniqueID` override. |
| `usePrivateWindowIDResolver` | `true` | `bool` | Use runtime `_AXUIElementGetWindow` lookup (`false` forces public geometric matching). |
| `pauseHotKey` | `ctrl+opt+cmd+f` | key spec | Global pause/resume shortcut via Carbon `RegisterEventHotKey`. |

## On-Desk Verification Checklist

Because headless build environments lack Camera and Accessibility grants, run these checks on your desk after building:

| Step | Command or action | Retires | Pass looks like |
|---|---|---|---|
| 1 | `scripts/bundle-app.sh && open dist/iFocus.app` | NV3 | Camera and Accessibility prompts name iFocus; the menu bar item appears. |
| 2 | `dist/iFocus.app/Contents/MacOS/ifocus --doctor` | | Window-ID resolver "private symbol"; every display and eligible window listed; match kind `exact` for each. |
| 3 | `... --doctor --focus-test` | NV2 | Selected windows receive keyboard focus; rung A for same-app windows; original focus restored. |
| 4 | Calibrate from the menu | NV1 | Cross-validation error at most 0.20 on every display; no "head barely moved" surprise. |
| 5 | Work for ten minutes | | Looking at an eligible window focuses it in ~1.2–1.5 s once idle; typing never loses focus. |
| 6 | `ifocus --doctor` on the **unlocked** desk | The unverified unlocked census | The occluder list holds only real panels and dialogs. No entry spans most of a display, and "prompt veto active" is "no" when no system dialog is open. |
| 7 | Trigger an authorisation dialog (for example unlock a pane in System Settings), then look at another window | AR1 | No switch while the dialog is up; the menu shows "System prompt on screen"; `--doctor` shows whether the owner was resolved by bundle ID or by process name. |
| 8 | Lock, wake the display without unlocking, then unlock | TRG-04 | Camera light stays off until the unlock. |
| 9 | During calibration press Esc, and in a second run click "Cancel (Esc)" | TRG-02 | Screens are uncovered at once both times; a paused agent stays paused. |
| 10 | Tilt the head about 15 degrees while looking at one window | TRG-25 | Focus does not jump to a neighbour. |
| 11 | Run the lifecycle smoke list below | TRG-16 | Quit returns within 2 s. |
| 12 | Hands off the keyboard, look at Spotify for a little over a second, press Space | Cross-app keyboard readiness | Playback toggles. |
| 13 | From Ghostty look at the second of two Chrome windows; then look at the first | Same-app window accuracy after an app change | The second window takes focus, not the first; then the first after about 1.5 s. |
| 14 | Type in Ghostty for ten seconds while reading Chrome, pause for a second, type again, then stop | The quiet-then-dwell model | No switch while typing or during the short pause; focus moves about four seconds after the last key. |
| 15 | `ifocus --doctor` | Scope and blocklist on real apps | `focusScope` is `allApps`; your password manager is listed as not eligible; "modifier held" is "no" with hands off the keyboard. |
| 16 | `ifocus --doctor --focus-test` | AW1 | Rung B for each app change, rung A inside one app, no `unverified`. If `unverified` appears for a slow app, the verification window is the knob. |
| 17 | Open Spotlight and read the results for two seconds | Spotlight as an occluder | The window behind it does not take focus and the panel stays open. |
| 18 | `scripts/bundle-app.sh --swiftpm` outside the sandbox | The SwiftPM bundle path, which has never run | A signed `dist/iFocus.app`. |

### Lifecycle Smoke List

1. Start iFocus and confirm tracking starts when unlocked and calibrated.
2. Pause and resume from both the menu bar item and the global hotkey (`ctrl+opt+cmd+f`).
3. Lock the screen and confirm the camera light goes off; unlock and confirm it comes back (`RB7`).
4. Unplug or cover-and-uncover an external camera (if one is used) and verify recovery.
5. Click Quit and verify the process exits within 2 s.

## Known Limits

- **Look-then-type trade-off:** Because hands-idle switching requires **1.2–1.5 s** of continuous gaze (and any keystroke clears pending progress), glancing at a target window and typing within about 1.2 s leaves focus on the previous window and delivers those keys there. Waiting for the subtle accent switch flash confirms focus moved before typing.
- **Unlisted AX windows & sheets:** A layer-0 sheet or helper window that an app omits from `kAXWindowsAttribute` fails with `.windowNotFound` and triggers the 2 s failure backoff before retrying.
- **Gaze spatial resolution:** Head pose reliably separates displays. Separating windows on the same display relies on pupil offset, which at 720p is accurate to roughly 5–8 degrees. One or two windows per display work reliably; dense quarter-display panes may require raising `dwellSameDisplaySeconds` and `stickyMarginPoints`.
- **Private AX symbol:** `_AXUIElementGetWindow` is resolved read-only at runtime via `dlopen`/`dlsym` inside [AXWindowID.swift](Sources/iFocusMac/Focus/AXWindowID.swift) with no link-time dependency. If macOS changes or removes the symbol (or if `usePrivateWindowIDResolver` is set to `false`), iFocus degrades to public frame-based matching ([AXWindowMatcher.swift](Sources/iFocusCore/Targeting/AXWindowMatcher.swift)).
- **Secure Keyboard Entry:** Password fields (including inside web browsers) and terminals with Secure Keyboard Entry (`IsSecureEventInputEnabled() == true`) activate the `.secureInput` safety veto when `respectSecureInput` is `true`, keeping focus locked until exited.
