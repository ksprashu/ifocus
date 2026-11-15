# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| `main` (current Wave 2 / v1.x) | Yes |

## Reporting a Vulnerability

Please report suspected security vulnerabilities privately through GitHub **Private Vulnerability Reporting** on this repository's **Security** tab (**Advisories -> Report a vulnerability**). Do not open public issues for undisclosed security bugs.

### In Scope

- Privilege, TCC permission, or input/occlusion bypasses in `iFocusCore`, `iFocusMac`, or `iFocusApp`
- File-system symlink/TOCTOU races or unsafe deserialisation in `SecureFileStore`, `ConfigStore`, or `ProfileStore`
- Build, bundling, code-signing, or CI workflow security issues under `scripts/` or `.github/workflows/`

## Privacy & Security Guarantees

- **Zero disk/network media persistence:** Camera frames stay strictly in memory (`CVPixelBuffer` -> Vision landmarks -> 6 scalar features), frames are decimated in memory (`FrameDecimator`), and `Sources/` contains zero networking APIs (enforced statically by invariant `I9` in `scripts/check-invariants.sh`).
- **No keylogging or event taps:** Input protection reads only OS idle-time counters (`CGEventSource.secondsSinceLastEventType`), modifier/button state (`CGEventSource.flagsState` / `buttonState`), and `IsSecureEventInputEnabled()` (`Sources/iFocusMac/Input/SystemInputActivityProvider.swift`). No `CGEventTap`, global NSEvent monitor, synthetic keystroke/mouse injection, or cursor warping is ever used (enforced by invariant `I1`).
- **No window titles read:** Window targeting reads Quartz layer, bounds, owner PID, and owner process/bundle metadata; `kCGWindowName` and `kAXTitleAttribute` are forbidden across `Sources/` (invariant `I1`).
- **Minimal TCC surface:** Requires only **Camera** and **Accessibility**; never requests Screen Recording or Input Monitoring.
- **Hardened local storage:** Configuration and calibration live in `~/Library/Application Support/iFocus/` (`0700` directory, `0600` regular files, `1 MiB` size ceiling), read and written via descriptor-pinned `open(..., O_DIRECTORY | O_NOFOLLOW)` + `fstat` + `openat`/`renameat`/`fsync` (`Sources/iFocusCore/Storage/SecureFileStore.swift`).
- **Unconditional sensitive-surface protection:** Authentication prompts (`SecurityAgent`, `coreautha`/`CoreAuthUI`, `UserNotificationCenter`, `CoreServicesUIAgent`, and high-layer `loginwindow` shields) enforce a global focus veto even on secondary displays; password managers, credential stores, Screen Sharing, System Settings, Spotlight, system chrome, and iFocus itself (`Bundle.main.bundleIdentifier` + `dev.ifocus.app`) are unconditionally blocklisted; lock-screen status is verified directly via `CGSessionCopyCurrentDictionary()`.
- **Optional private AX resolver:** `_AXUIElementGetWindow` is resolved read-only via `dlopen`/`dlsym` strictly inside `Sources/iFocusMac/Focus/AXWindowID.swift` (invariant `I5`) with a pure public frame-matching fallback (`usePrivateWindowIDResolver: false`).
