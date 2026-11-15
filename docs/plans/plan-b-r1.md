# iFocus Technical Architecture & Implementation Plan (Plan B - Round 1)

**Author Role:** `planner-b` (Systems, Computer Vision & macOS Accessibility Specialist)  
**Target Workspace:** the repository root  
**Toolchain Verified:** `Apple Swift version 6.4 (arm64-apple-macosx26.0)`, macOS `26.7.2` (`MacOSX.sdk`), CommandLineTools only (no `Xcode.app`)

---

## 1. Executive Summary & Core Architectural Bets

`iFocus` solves a specific multi-monitor terminal workflow failure: a developer running 4-5 terminal windows across multiple displays looks at a target terminal (for example, right monitor, right column), begins typing or hits `Enter`, and executes commands inside a stale focused terminal (for example, top-left of left monitor).

Plan B builds `iFocus` around five foundational engineering bets:

1. **Physical-Workspace + Topological Coordinate Grounding:** Combine `CGDisplayBounds` (Quartz logical points) with `CGDisplayScreenSize` (physical millimetres), `CGDisplayIsBuiltin`, and a configurable **Webcam Bezel Anchor** (`CameraBezelAnchor`) so gaze vectors account for unequal display DPIs, negative multi-display Quartz offsets, and camera lens FOV (`AVCaptureDeviceFormat.videoFieldOfView`). Convert between Quartz top-left coordinates and AppKit bottom-left coordinates strictly via the **primary display height** (`H_0 = primaryDisplayBounds.height`), avoiding the classic per-screen height inversion bug.
2. **Head-Pose + De-Rolled Eye-in-Head Fusion (`76`-Point Vision):** Fuse `VNFaceObservation` head angles (`yaw`, `pitch`, `roll`) and inter-ocular 3D distance estimation with roll-compensated pupil-to-canthus normalized eye offsets `(e_x, e_y)` from `VNDetectFaceLandmarksRequest` (`VNDetectFaceLandmarksRequestRevision3`, `.constellation76Points`), guarded by an Eye Aspect Ratio (`EAR`) blink gate and `faceCaptureQuality` confidence score.
3. **Topology-Keyed Ridge-Regression Calibration + One-Euro Filtering:** Provide an immediate uncalibrated 3D ray-plane baseline, upgraded by a quick 5-point global or 4-corner-per-monitor calibration solved via regularised Ridge Regression (`(Phi^T Phi + lambda I) W = Phi^T Y`) with automatic basis rank step-down and singularity protection. Persist calibration profiles keyed by a canonical `TopologyFingerprint` (`vendor`, `model`, `serial`, `bounds`, `cameraID`) so plugging/unplugging external monitors switches calibration automatically. Smooth `(gx, gy)` with an adaptive **One-Euro filter** plus a **saccade-velocity gate** so cross-monitor eye sweeps never trigger intermediate windows.
4. **Zero-SPI Same-PID `AXUIElement` Disambiguation:** Resolve the topmost unoccluded window at `(gx, gy)` from front-to-back `CGWindowListCopyWindowInfo`, then match that `CGWindowCandidate` to its exact `AXUIElement` inside `AXUIElementCreateApplication(pid)` (`AXUIElementSetMessagingTimeout(..., 0.25)`) using **100% public Accessibility attributes** (`kAXPositionAttribute`, `kAXSizeAttribute`, `kAXTitleAttribute`, `kAXMinimizedAttribute`, `kAXSubroleAttribute`) scored by Intersection-over-Union (`IoU`) + corner L1 error + title tie-breaking (no private `_AXUIElementGetWindow` SPI). Focus without moving the mouse cursor via `kAXMainAttribute` -> `kAXFocusedAttribute` -> `kAXRaiseAction` -> cooperative `NSRunningApplication.activate(options: [])`.
5. **Zero-Keylogging Safety Guards & Zero-Disk-Frame Privacy:** Freeze focus switching during active typing via `CGEventSource.secondsSinceLastEventType` (`.keyDown` + `.flagsChanged`) with zero `CGEventTap` and zero Input Monitoring permission. Respect `IsSecureEventInputEnabled()`, manual mouse/trackpad movement, look-down-at-keyboard pitch decay, screen lock (`com.apple.screenIsLocked`), and sleep/wake lifecycle (halting `AVCaptureSession` immediately so the webcam LED turns off).

---

## 2. Environment & Toolchain Constraints (Verified Empirically)

| Constraint | Verified Fact in Workspace | Architectural / Build Implication |
| :--- | :--- | :--- |
| **Swift Toolchain** | `Apple Swift version 6.4`, `arm64-apple-macosx26.0`, `/Library/Developer/CommandLineTools` | Use `// swift-tools-version: 6.0` with `.macOS(.v14)` platform target and Swift 6 strict concurrency (`Sendable`, actors, `@MainActor`). |
| **Test Framework** | `Xcode.app` is **not** installed; `XCTest.framework` is absent from CLT, whereas `Testing.framework` IS installed (`.../CommandLineTools/Library/Developer/Frameworks/Testing.framework`). | **MANDATORY:** All test suites in `Tests/iFocusCoreTests/` MUST use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`) and NEVER `import XCTest`. |
| **Agent Sandbox SwiftPM** | Nested `sandbox-exec` (`sandbox_apply`) and `/var/folders` caches fail in Standard Sandbox Mode. | Build/test invocations in sandbox must set `TMPDIR=/tmp CLANG_MODULE_CACHE_PATH=/tmp/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swiftpm-cache`, pass `--disable-sandbox` (and `--disable-xctest` if needed), and isolate scratch paths (`--scratch-path /tmp/ifocus-<role>`). |
| **TCC App Identity** | Unbundled CLI binaries lack `Info.plist` (`NSCameraUsageDescription`) and trigger macOS `SIGABRT` on camera start, plus unstable TCC identity across rebuilds. | Ship `Resources/Info.plist` (`LSUIElement = true`, `NSCameraUsageDescription`) and `scripts/bundle-app.sh` producing `dist/iFocus.app` with deterministic ad-hoc signing (`codesign --force --sign - --identifier com.ifocus.app`). |

---

## 3. System Architecture & Data Pipeline

### 3.1 End-to-End Frame-to-Focus Pipeline

```text
[AVCaptureSession (15-20 FPS, 420f, alwaysDiscardsLateVideoFrames=true)]
       |  (dedicated serial videoQueue; CVPixelBuffer never escapes callback)
       v
[VisionFaceLandmarkExtractor (VNSequenceRequestHandler + VNDetectFaceLandmarksRequest rev3 76pt)]
       |  (emits immutable Sendable RawFaceObservation via AsyncStream bufferingNewest(1))
       v
[GazeGeometryAndCalibrationEngine]
  1. Blink gate (Eye Aspect Ratio < 0.16) & faceCaptureQuality gate
  2. Roll-compensated pupil offset (e_x, e_y) + head (yaw, pitch, roll) + 3D IPD head offset
  3. Uncalibrated 3D-ray-to-workspace-plane (mm) OR Ridge-Regression calibration (gx, gy)
  4. OneEuroFilter2D smoothing + saccade velocity detector
       |  (emits FilteredGazeSample: point, confidence, velocity, pitch, timestamp)
       v
[DisplayTopologyService] + [CGWindowList Z-Order Occlusion Resolver]
  - Global Quartz bounds, primary-height AppKit <-> Quartz transforms
  - Front-to-back hit-test with active-window sticky margin (anti-border-thrash)
       |  (emits TargetWindowCandidate or nil)
       v
[FocusDecisionEngine (Deterministic State Machine)]
  - Gates: paused | screenLocked | secureInput | typingLock | manualPointerLock | lookDownLock | lowConfidence | saccadeTransit | cooldown | dwell(>=220ms)
       |  (commits FocusSwitchCommand)
       v
[AccessibilityFocusSwitcher (250ms AX timeout, background actor -> @MainActor activate)]
  - Matches CGWindowCandidate -> AXUIElement (IoU + L1 + Title)
  - kAXMainAttribute=true -> kAXFocusedAttribute=true -> kAXRaiseAction -> activate(options: [])
       |
       v
[FocusHighlightOverlay (opt-in 450ms non-activating NSPanel border pulse)]
```

### 3.2 SwiftPM Package & Module Layout

```text
Package.swift                          # swift-tools-version: 6.0, macOS 14+, Swift 6 strict concurrency
Resources/
  Info.plist                           # NSCameraUsageDescription, LSUIElement=1, CFBundleIdentifier=com.ifocus.app
scripts/
  bundle-app.sh                        # Builds release/debug iFocusApp, packages iFocus.app, codesigns deterministically
Sources/
  iFocusCore/
    Models/
      GeometryTypes.swift              # QuartzPoint, QuartzRect, AppKitRect, PhysicalWorkspaceRect, DisplayDescriptor
      GazeTypes.swift                  # RawFaceObservation, GazeFeatures, FilteredGazeSample, CalibrationSample
      WindowTypes.swift                # CGWindowCandidate, AXWindowSnapshot, TargetFilterMode, FocusSwitchDecision
      ConfigTypes.swift                # IFocusConfig, CameraBezelAnchor, CalibrationProfile, TopologyFingerprint
    Protocols/
      Services.swift                   # GazeEstimator, DisplayTopologyProviding, WindowCatalogProviding,
                                       # FocusSwitching, ActivityGuardProviding, FocusHighlightPresenting
    Geometry/
      CoordinateTransform.swift        # Exact Quartz <-> AppKit conversion via H_0, physical mm workspace mapper
      GazeRayModel.swift               # 3D head-pose + de-rolled pupil fusion, EAR blink gate, uncalibrated ray-plane hit
      OneEuroFilter.swift              # Casiez et al. 1-Euro adaptive 2D filter + saccade velocity state
      CalibrationSolver.swift          # Regularised Ridge Regression + rank fallback + leave-one-out / residual RMSE
    Focus/
      AXWindowMatcher.swift            # Pure IoU + corner L1 + title scoring matcher for same-PID multi-window AX matching
      WindowHitTester.swift            # Front-to-back CGWindow occlusion walk, system-UI denylist, sticky margin hysteresis
      FocusDecisionEngine.swift        # Deterministic FSM: dwell, cooldown, typing-lock, mouse-lock, pitch-lock, secure-input
    Storage/
      CalibrationStore.swift           # Topology-keyed JSON store (~/Library/Application Support/iFocus), 0600 perms, symlink guard
    Platform/
      LiveDisplayTopologyService.swift # CGGetActiveDisplayList, CGDisplayBounds, CGDisplayScreenSize, CGDisplayIsBuiltin
      LiveWindowCatalogService.swift   # CGWindowListCopyWindowInfo + AXUIElementCreateApplication (0.25s timeout) snapshotter
      LiveAccessibilityFocusSwitcher.swift # Public AX raise + main + cooperative NSRunningApplication.activate
      LiveActivityGuardService.swift   # CGEventSource.secondsSinceLastEventType, IsSecureEventInputEnabled, lock/sleep notifications
      VisionCameraGazeEstimator.swift  # AVCaptureSession (15-20 FPS, 420f) + VNDetectFaceLandmarksRequest rev3 76pt
      SimulatedServices.swift          # Deterministic scriptable mocks for offline 4-5 terminal multi-monitor simulation & tests
  iFocusApp/
    iFocusMain.swift                   # Entrypoint: CLI (--doctor, --simulate, --calibrate, --run, --status) + NSApplication runloop
    MenuBarController.swift            # @MainActor NSStatusItem, enable/pause, target mode toggle, profile status, open System Settings
    CalibrationOverlayController.swift # @MainActor multi-monitor borderless NSPanel target dots (5-pt global & 4-corner per-display)
    FocusHighlightOverlay.swift        # @MainActor 450ms subtle non-activating border flash around newly focused terminal
    PipelineCoordinator.swift          # Wires live services, handles sleep/lock camera teardown, bounded telemetry ring buffer
Tests/
  iFocusCoreTests/
    CoordinateTransformTests.swift     # Unequal-height / negative-offset Quartz <-> AppKit round-trip & physical mm tests
    OneEuroFilterTests.swift           # Stationary jitter reduction, step-response lag, dt<=0 & gap-reset stability
    CalibrationSolverTests.swift       # Synthetic dual-monitor calibration, collinear/NaN resilience, rank-stepdown tests
    AXWindowMatcherTests.swift         # Same-PID 5-terminal disambiguation across monitors, overlapping identical-bounds tie-break
    FocusDecisionEngineTests.swift     # 4-5 terminal multi-monitor scenarios, typing-lock, pitch look-down, saccade transit, secure input
    CalibrationStoreTests.swift        # POSIX 0600 permission check, symlink rejection, topology fingerprint switching
```

---

## 4. Deep-Dive Technical Specifications

### 4.1 Multi-Monitor Coordinate Systems & Physical Bezel Geometry

#### A. Exact Quartz <-> AppKit Conversion (Zero Multi-Monitor Y-Flip Bug)
In macOS:
- **Quartz global display space** (`CGDisplayBounds`, `CGWindowListCopyWindowInfo` `kCGWindowBounds`, `AXUIElement` `kAXPositionAttribute`/`kAXSizeAttribute`) places `(0, 0)` at the **top-left of the primary display** (`CGMainDisplayID()`), with `+X` right and `+Y` **down**. Displays above or left of primary have negative coordinates.
- **AppKit screen space** (`NSScreen.screens`, `NSPanel.setFrame`) places `(0, 0)` at the **bottom-left of `NSScreen.screens[0]`** (the primary display), with `+X` right and `+Y` **up**.

Conversion MUST always use `H_0 = CGDisplayBounds(CGMainDisplayID()).height`, **never** the local display's height:
- Quartz point `(qx, qy)` -> AppKit point `(ax, ay)`:
  `ax = qx`, `ay = H_0 - qy`
- Quartz rect `(qx, qy, w, h)` -> AppKit rect `(ax, ay, w, h)`:
  `ax = qx`, `ay = H_0 - qy - h`
- AppKit rect `(ax, ay, w, h)` -> Quartz rect `(qx, qy, w, h)`:
  `qx = ax`, `qy = H_0 - ay - h`

*Verification example:* Primary laptop `(0, 0, 1512, 982)` (`H_0 = 982`) and external 4K monitor to the left aligned along the bottom edge (`w=2560, h=1440`):
- Quartz bounds of left monitor: `(-2560, -458, 2560, 1440)`.
- Formula yields AppKit rect: `ax = -2560`, `ay = 982 - (-458) - 1440 = 0`, `w = 2560`, `h = 1440`. Exact match.

#### B. Physical Millimetre Workspace & Camera Bezel Anchor
1. Enumerate displays with `CGGetActiveDisplayList(16, &ids, &count)`.
2. For each `displayID`:
   - `boundsPt = CGDisplayBounds(displayID)` (Quartz logical points).
   - `rawMM = CGDisplayScreenSize(displayID)`. If `rawMM.width <= 1.0 || rawMM.height <= 1.0` (headless/virtual display or missing EDID), fallback to `CGSize(width: boundsPt.width / (72.0 / 25.4), height: boundsPt.height / (72.0 / 25.4))` (`~2.8346 pt/mm`).
   - Compute per-display scale `mmPerPtX = rawMM.width / boundsPt.width`, `mmPerPtY = rawMM.height / boundsPt.height`.
   - Identify `isBuiltin = CGDisplayIsBuiltin(displayID) != 0`.
3. **Webcam Bezel Anchor (`CameraBezelAnchor`):**
   - Stores `hostDisplayID: CGDirectDisplayID` (defaults to the built-in display if open, else `CGMainDisplayID()`, or user-selected external display if MacBook is in clamshell mode with a Studio Display / external webcam), `normalizedXOnTopBezel: Double = 0.5`, `verticalOffsetAboveTopMM: Double = -6.0` (camera lens sits ~6 mm above top active pixel edge), and `cameraPitchBiasRad: Double = 0.0`.
   - Anchor point in Quartz logical workspace: `camAnchorPt = CGPoint(x: hostBounds.minX + hostBounds.width * anchor.normalizedXOnTopBezel, y: hostBounds.minY)`.

---

### 4.2 Computer Vision Gaze Estimation (`AVFoundation` + `Vision`)

#### A. Camera Capture Settings (15-20 FPS Low-Power Pipeline)
- **Device discovery:** `AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)` — prefers built-in camera when laptop lid is open (unless user selects a specific external camera by `uniqueID`).
- **Frame rate throttling at ISP level:** Configure `AVCaptureDeviceInput.videoMinFrameDurationOverride = CMTime(value: 1, timescale: 20)` (`20 fps` active, automatically stepping down to `8 fps` when `TypingLock` or `Idle` holds for `> 5 s` via `activeVideoMinFrameDuration`!).
- **Format & pixel buffer:** Select a `640x480` or `1280x720` `420f`/`420v` (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`) format to minimize memory bandwidth and avoid CPU RGB conversion; read `activeFormat.videoFieldOfView` (degrees; fallback `65.0°`).
- **Queue discipline:** `videoOutput.alwaysDiscardsLateVideoFrames = true`, serial `DispatchQueue(label: "com.ifocus.vision", qos: .userInteractive)`.

#### B. Vision Extraction (`VNDetectFaceLandmarksRequest`)
Inside `captureOutput(_:didOutput:from:)`:
1. Determine mirroring flag (`connection.isVideoMirrored`) and EXIF orientation (`.up` for unmirrored macOS landscape webcam, `.upMirrored` if mirrored — normalize X consistently before emitting features).
2. Run `VNSequenceRequestHandler.perform([landmarksRequest], on: pixelBuffer, orientation: .up)` where:
   - `landmarksRequest = VNDetectFaceLandmarksRequest()`
   - `landmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3`
   - `landmarksRequest.constellation = .constellation76Points`
3. Select the primary face observation (`observations.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })`).
4. Extract immediately into an immutable `Sendable` struct `RawFaceObservation` (`pixelBuffer` and `VNFaceObservation` NEVER leave the callback):
   - `yaw = face.yaw?.doubleValue` (`[-pi/2, pi/2]`)
   - `pitch = face.pitch?.doubleValue` (`[-pi/2, pi/2]`; per `VNObservation.h`, positive = nodding head **down**)
   - `roll = face.roll?.doubleValue` (`[-pi, pi)`)
   - `faceCenterNorm` = midpoint of `face.boundingBox`
   - Eye landmarks in **image pixel coordinates** (`region.pointsInImage(imageSize:)`):
     - `leftEye` contour, `rightEye` contour, `leftPupil` centroid, `rightPupil` centroid
     - Landmark `confidence = Double(landmarks.confidence)` and mean pupil precision from `precisionEstimatesPerPoint` (if present).
5. Yield `RawFaceObservation` into `AsyncStream` with `.bufferingPolicy(.bufferingNewest(1))`. Zero video frames are ever saved, copied to disk, or logged.

#### C. De-Rolled Eye-in-Head Vector + Blink Gate + 3D Ray Baseline
Given `leftEye` points `{p_0..p_{k-1}}`, `leftPupil` centroid `q_L`, and head `roll`:
1. Rotate eye contour and pupil by `-roll` around the eye centroid so tilted heads do not mix horizontal and vertical eye motion.
2. Compute eye horizontal corners `x_min, x_max`, eye width `W_eye = max(x_max - x_min, 1e-4)`, and vertical opening `H_eye = y_max - y_min`.
3. **Blink Gate (`EAR`):** `ear = H_eye / W_eye`. Typical open eye `ear ∈ [0.20, 0.40]`; blink `ear < 0.16`. When `min(earL, earR) < 0.16`, mark `isBlinking = true` and **hold previous `(e_x, e_y)`** rather than emitting noisy lid-closure pupil offsets!
4. **Normalized Pupil-in-Socket Offset:**
   - `e_x = clamp(2.0 * ((q.x - eyeCenter.x) / W_eye), -1.0, 1.0)` (averaged across left/right eyes).
   - `e_y = clamp(2.0 * ((q.y - eyeCenter.y) / max(H_eye, 0.25 * W_eye)), -1.0, 1.0)` (scaled by `0.25 * W_eye` instead of instantaneous `H_eye` so partial squinting does not amplify vertical jitter!).
5. **Head 3D Position Estimate (`IPD` + FOV):**
   - Inter-ocular pixel distance `iodPx = hypot(eyeCenterR.x - eyeCenterL.x, eyeCenterR.y - eyeCenterL.y)`.
   - Focal length in pixels: `f_px = (imageWidth / 2.0) / tan(fovRad / 2.0)`.
   - Estimated distance from camera: `Z_mm = clamp(63.0 * f_px / max(iodPx, 10.0), 250.0, 1400.0)` (63 mm mean adult IPD).
   - `X_head_mm = ((faceCenterNorm.x - 0.5) * imageWidth / f_px) * Z_mm`, `Y_head_mm = ((0.5 - faceCenterNorm.y) * imageHeight / f_px) * Z_mm`.
6. **Uncalibrated Geometric Baseline (Immediate Out-of-Box Accuracy):**
   - Total gaze yaw/pitch angles:
     `theta_x = headGainX * yaw + eyeGainX * e_x` (default `headGainX = 1.0, eyeGainX = 0.42 rad`)
     `theta_y = headGainY * (-pitch) + eyeGainY * e_y` (default `headGainY = 1.0, eyeGainY = 0.28 rad`)
   - Project ray `(tan(theta_x), tan(theta_y)) * Z_mm` from `(X_head_mm, Y_head_mm)` onto the workspace plane relative to `CameraBezelAnchor`, then scale by host display `pt/mm` into global Quartz coordinates.

---

### 4.3 Regularised Ridge-Regression Calibration & One-Euro Smoothing

#### A. Per-Topology Ridge-Regression Calibration (`CalibrationSolver`)
To eliminate desk-tilt parallax, monitor elevation differences, and user-specific eye asymmetry:
- **Calibration Modes:**
  - **5-Point Global Calibration (Default, ~7s):** Centre + 4 global workspace extremes across the combined multi-display bounding hull.
  - **4-Corner Per-Monitor Calibration (~5s/display):** 4 inset corners `(8% margin)` on each connected display, ideal when external monitors sit at different heights/depths than the MacBook.
- **Sample Acquisition per Target:** Show pulsing target dot; discard first `300 ms` (saccade latency); record `18` open-eye non-blinking frames (`~900 ms`); reject top/bottom `20%` by distance from feature median (MAD outlier trimming) -> emit robust target sample.
- **Feature Vector `phi` & Adaptive Basis Step-Down:**
  - Full 9-term basis (used when `N_targets >= 9` and condition passes):
    `phi_9 = [1, yaw, pitch, e_x, e_y, X_head_mm / 500, Y_head_mm / 500, yaw * e_x, pitch * e_y]`
  - Linear 5-term basis (used when `5 <= N_targets < 9`, e.g., 5-point global or single-monitor 4-corner + center):
    `phi_5 = [1, yaw, pitch, e_x, e_y]`
  - Head-only 3-term fallback (if pupils unavailable or `N_targets < 5`):
    `phi_3 = [1, yaw, pitch]`
- **Regularised Normal Equations (Pure Swift, Zero External Dependencies):**
  - Standardise non-constant features (`(x - mean) / max(std, 1e-4)`) so `lambda` regularises all dimensions uniformly!
  - Solve `(Z^T Z + diag(0, lambda, ..., lambda)) w_x = Z^T q_x` and `w_y = ...` (`lambda = 0.08`) using Gaussian elimination with partial pivoting.
  - Guardrails: Verify pivot `>= 1e-8`, verify finite weights (`allSatisfy(\.isFinite)`), and compute Leave-One-Out or In-Sample RMSE (`pt`). If ill-conditioned (for example, collinear points), automatically step down basis (`phi_9 -> phi_5 -> phi_3`) or return `.degenerateCalibration` error without ever producing `NaN`.
- **Topology-Keyed Persistence (`CalibrationStore`):**
  - Compute `TopologyFingerprint` = `SHA256` (via `CryptoKit`) over sorted active displays `[(vendorNumber, modelNumber, serialNumber, bounds)]` + `cameraUniqueID`.
  - Store dictionary `[TopologyFingerprint: CalibrationProfile]` in `~/Library/Application Support/iFocus/calibration.json` (`0700` dir, `0600` file, atomic write via temporary file in the same directory).

#### B. One-Euro Adaptive Filter + Saccade Velocity Gate (`OneEuroFilter2D`)
For each frame with sample interval `dt = t_now - t_prev`:
- If `dt <= 0`: skip update (or clamp minimum `1e-4`); if `dt > 0.5 s` (after blink/pause/sleep): reset filter internal state cleanly to current raw sample to avoid derivative spike!
- Apply Casiez et al. (2012) 1-Euro filter independently on `x` and `y`:
  - `alpha(cutoff, dt) = 1.0 / (1.0 + (1.0 / (2.0 * .pi * cutoff)) / dt)`
  - Derivative estimate: `dx_hat = lowPass((x - x_prev) / dt, alpha(dCutoff=1.0, dt))`
  - Adaptive cutoff: `cutoff = minCutoff + beta * abs(dx_hat)` (defaults: `minCutoff = 1.2 Hz`, `beta = 0.010`, `dCutoff = 1.0 Hz`)
  - Output: `x_hat = lowPass(x, alpha(cutoff, dt))`
- **Saccade Gate:** Compute instantaneous filtered speed `v = hypot(vx, vy)` (`pt/s`). When `v > 2000 pt/s`, flag `inSaccade = true` and hold dwell state until `v < 450 pt/s` for 2 consecutive frames, preventing accidental focus triggers on intermediate windows between left and right monitors.

---

### 4.4 Same-PID Multi-Terminal Resolution & Occlusion-Aware Switching

#### A. Z-Order Occlusion Resolver (`WindowHitTester`)
1. Query `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` (returns windows strictly front-to-back).
2. Filter to eligible candidates:
   - `kCGWindowLayer == 0` (ignores Dock, menu bar, Spotlight, iFocus's own HUD/overlays, notifications).
   - `kCGWindowAlpha > 0.01` and `kCGWindowIsOnscreen == true`.
   - `bounds.width >= 80 && bounds.height >= 60`.
   - `ownerPID != ProcessInfo.processInfo.processIdentifier`.
   - Exclude protected/system processes: `SecurityAgent`, `CoreServicesUIAgent`, `loginwindow`, `ScreenSaverEngine`, `NotificationCenter`, `ControlCenter`, `UserNotificationCenter`, `WindowManager`, `Dock`.
   - Apply `TargetFilterMode`:
     - `.allStandardWindows` (switches across terminals, editors, browsers, etc.)
     - `.allowlistedAppsOnly(bundleIDs)` (preset includes `com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`, `net.kovidgoyal.kitty`, `org.alacritty`, `com.github.wez.wezterm`, `dev.warp.Warp-Stable`, `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92`, `dev.zed.Zed`).
3. **Front-to-Back Hit Test + Sticky Margin:**
   - First, check if `(gx, gy)` hits a window **above** `currentFocusedWindowID` in z-order (for example, a floating terminal overlapping part of a larger window): if `(gx, gy)` is inside `w.bounds.insetBy(dx: min(10, w.width*0.1), dy: min(10, w.height*0.1))`, select `w`.
   - Otherwise, if `currentFocusedWindow` exists and `currentFocusedWindow.bounds.insetBy(dx: -16, dy: -16).contains(gx, gy)` (sticky margin!), keep `currentFocusedWindow` to prevent border thrashing between adjacent tiled terminals.
   - Otherwise, return the first window in front-to-back order whose `bounds` contains `(gx, gy)`.

#### B. Zero-SPI Same-PID `AXUIElement` Window Matching (`AXWindowMatcher`)
Given `target: CGWindowCandidate` (with `ownerPID`, `bounds`, `title`, `windowID`):
1. Create `appElement = AXUIElementCreateApplication(target.ownerPID)` and immediately set `AXUIElementSetMessagingTimeout(appElement, 0.25)` so hung apps cannot block iFocus.
2. Fetch `kAXWindowsAttribute` (`CFArray` of `AXUIElement`). For each element, capture an `AXWindowSnapshot`:
   - `kAXMinimizedAttribute` (`Bool`, default `false`) -> skip minimized windows.
   - `kAXSubroleAttribute` (`String?`) -> check `kAXStandardWindowSubrole`.
   - `kAXPositionAttribute` (`CGPoint` via `AXValueGetValue(..., .cgPoint, ...)`).
   - `kAXSizeAttribute` (`CGSize` via `AXValueGetValue(..., .cgSize, ...)`).
   - `kAXTitleAttribute` (`String?`).
   - `kAXMainAttribute` (`Bool`).
3. **Scoring Function (Pure Swift, Unit-Tested):**
   - For each non-minimized `AXWindowSnapshot`:
     - Compute `iou = intersectionArea(axRect, target.bounds) / unionArea(axRect, target.bounds)`.
     - Compute `cornerL1 = abs(ax.minX - cg.minX) + abs(ax.minY - cg.minY) + abs(ax.width - cg.width) + abs(ax.height - cg.height)`.
     - Discard candidates with `iou < 0.70 && cornerL1 > 24.0`.
     - Compute title score:
       - Exact non-empty `axTitle == cgTitle`: `+500.0`
       - Case-insensitive / prefix containment (since some terminals truncate AX vs CG titles slightly): `+150.0`
       - `subrole == kAXStandardWindowSubrole`: `+50.0`
     - `totalScore = iou * 1000.0 - cornerL1 * 0.5 + titleBonus`.
   - Select maximum-scoring `AXWindowSnapshot`. This resolves 4-5 Terminal.app / iTerm2 / Ghostty windows sharing 1 PID across multiple monitors, AND cleanly handles two overlapping same-size windows via title tie-breaking!

#### C. Cursor-Free Focus Activation Order
1. **Idempotency check:** Query currently focused app PID (`NSWorkspace.shared.frontmostApplication?.processIdentifier`) and its `kAXFocusedWindowAttribute`; if its bounds/title already match `target` (`IoU >= 0.95` and title matches), return `.alreadyFocused` with zero AX mutations.
2. **Pre-commit TOCTOU re-check:** Re-verify `ActivityGuardService` (`typingLock`, `secureInput`, `screenLocked`, `manualPointerLock`) immediately before mutating AX state.
3. **Mutation sequence (no mouse movement):**
   - `AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)`
   - `AXUIElementSetAttributeValue(axWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)` (tolerate `.attributeUnsupported` on terminals that expose focus strictly through `kAXMainAttribute` + `kAXRaiseAction`)
   - `AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)`
   - If `target.ownerPID != frontmostPID`: dispatch to `@MainActor` `NSRunningApplication(processIdentifier: target.ownerPID)?.activate(options: [])` (never `.activateAllWindows`, never deprecated `.activateIgnoringOtherApps`), then re-assert `kAXMainAttribute = true` + `kAXRaiseAction` once if needed so multi-window apps never pop their previous key window ahead of `axWin`.

---

### 4.5 Safety State Machine (`FocusDecisionEngine`)

| Guard / State | Trigger Condition | Effect on Focus Switching | Default Threshold |
| :--- | :--- | :--- | :--- |
| **Paused / Off** | Menu-bar pause, CLI pause | Suppresses switches; stops camera capture | Manual toggle |
| **Screen Lock / Sleep** | `com.apple.screenIsLocked`, `willSleepNotification`, `kCGSessionOnConsoleKey == false` | Stops `AVCaptureSession` immediately (LED off) | Instant |
| **Secure Input Lock** | `IsSecureEventInputEnabled() == true` | Freezes focus (protects password/sudo prompts; user-overridable if Terminal Secure Entry enabled globally) | Instant |
| **Typing-Cadence Lock** | `min(secondsSince(.keyDown), secondsSince(.flagsChanged)) < window` via `CGEventSource` | Freezes focus on active terminal while typing (zero keylogging / zero `CGEventTap`) | `0.90 s` |
| **Manual Pointer Lock** | `secondsSince(.mouseMoved) < 1.2 s` or `secondsSince(.leftMouseDown) < 2.0 s` | Yields control to mouse/trackpad | `1.2 s / 2.0 s` |
| **Look-Down / Quality Lock** | `pitch > +0.30 rad` (looking at keyboard) OR `|yaw| > 0.78 rad` OR `confidence < 0.45` | Decays & freezes focus on current window | `> +0.30 rad` |
| **Saccade Transit Gate** | Filtered gaze speed `> 2000 pt/s` until `< 450 pt/s` | Clears dwell accumulator; ignores flyover windows | `2000 -> 450 pt/s` |
| **Dwell Hysteresis** | Continuous target match (tolerating `<= 60 ms` blink drop) | Commits focus switch only after dwell completes | `220 ms` |
| **Post-Switch Cooldown** | After any successful focus switch | Prevents oscillation/ping-pong | `350 ms` |

---

## 5. Swift 6.4 Concurrency, Security & Privacy Threat Model

1. **Strict Actor Isolation & Memory Safety:**
   - `RawFaceObservation`, `FilteredGazeSample`, `CGWindowCandidate`, `DisplayDescriptor`, `IFocusConfig`, and `CalibrationProfile` are immutable `Sendable` value types (`struct`/`enum`).
   - `AVCaptureSession` lifecycle runs exclusively on a dedicated `cameraQueue` (`DispatchQueue`), never blocking `@MainActor`.
   - `CVPixelBuffer` is consumed strictly inside `captureOutput(_:didOutput:from:)` and released on scope exit. Zero frame buffers or images are copied, persisted, logged, or transmitted.
   - `AXUIElement` IPC executes on a dedicated `FocusSwitcherActor` with `AXUIElementSetMessagingTimeout(..., 0.25)`; only `NSRunningApplication.activate`, `NSStatusItem`, and `NSPanel` overlays execute on `@MainActor`.
2. **Privacy & TCC Least Privilege:**
   - Requires **only** Camera (`NSCameraUsageDescription`) and Accessibility (`AXIsProcessTrustedWithOptions`).
   - Requires **zero** Input Monitoring (`CGEventTap`), **zero** Screen Recording (`CGWindowListCopyWindowInfo` reads window metadata bounds/PID/layer only; window titles are NOT requested if `ScreenRecording` is ungranted, wait — on macOS 10.15+, `kCGWindowName` requires Screen Recording TCC for other apps' titles, whereas `kAXTitleAttribute` via Accessibility TCC ALREADY returns exact window titles for all windows! Plan B explicitly uses `kAXTitleAttribute` from Accessibility TCC and treats `kCGWindowName` as optional!).
   - **Important macOS TCC Discovery Note:** On macOS Sequoia/Tahoe, `CGWindowListCopyWindowInfo` returns `kCGWindowOwnerPID` and `kCGWindowBounds` without Screen Recording permission, while `kCGWindowName` may be omitted unless Screen Recording is granted — whereas `AXUIElement` `kAXTitleAttribute` works with **Accessibility permission alone**! Therefore, geometric `IoU` + `L1` bounds matching is primary, with optional title tie-breaking using `kCGWindowName` when available or `AXWindows` z-order.
   - Telemetry/logs redact window titles by default unless explicit `--debug-titles` flag is set.
3. **Config & Storage Security (`CalibrationStore`):**
   - Reject custom paths containing `..` segments or pointing to symlinks (`lstat` / `URLResourceValues.isSymbolicLinkKey`).
   - Enforce `0700` directory and `0600` file permissions on `~/Library/Application Support/iFocus/calibration.json`.
   - Validate all loaded floats (`isFinite`, reasonable physical bounds) and schema version.

---

## 6. Clear Separation: v1 MVP Scope vs v2 Roadmap

### v1 Buildable Scope (Implement in Round 1)
1. **`Package.swift` + `iFocusCore` Library:** All coordinate math, physical mm topology + bezel anchor, Vision 76-pt head+pupil fusion + EAR blink gate, One-Euro filter + saccade gate, Ridge-Regression calibration solver + topology-keyed JSON store, zero-SPI public `AXWindowMatcher` + `AccessibilityFocusSwitcher`, `WindowHitTester` with sticky margin, `FocusDecisionEngine` state machine, and deterministic `SimulatedServices`.
2. **`iFocusApp` Native macOS Menu-Bar + CLI:**
   - CLI modes: `--doctor` (TCC/display/camera/AX diagnostics), `--simulate` (runs multi-monitor 4-5 terminal scripted scenario and prints trace), `--calibrate` (launches interactive overlay), `--run` (starts menu bar + tracking loop).
   - Menu-bar `NSStatusItem` (`LSUIElement = true`) with Pause/Resume, Target Mode (`All Windows` / `Terminals & IDEs`), Quick Calibrate (5-pt Global / 4-Corner Per-Monitor), Calibration Profile indicator, Live Safety Lock reason (`Typing`, `Look-Down`, `Secure Input`, `Active`), and TCC permission prompts.
   - Interactive `CalibrationOverlayController` (`NSPanel` across active screens) + lightweight `450 ms` opt-in `FocusHighlightOverlay` border flash on switch.
   - `Resources/Info.plist` + `scripts/bundle-app.sh`.
3. **`iFocusCoreTests` (Swift Testing):** Full offline verification of every math, matching, security, and 4-5 terminal multi-monitor focus scenario.

### v2 Roadmap (Prioritised Next-Wave Extensions — Deferred Out of v1)

| Priority | Feature | User Value for 4-5 Terminal Workflow | Complexity & Risk |
| :--- | :--- | :--- | :--- |
| **P1** | **Terminal Split-Pane & `tmux` Bridge** | Focus individual splits inside one iTerm2 / Ghostty / `tmux` / WezTerm window (where OS `AXWindows` sees only 1 outer window). | Medium (app-specific AppleScript / `tmux select-pane` IPC + pane geometry lookup). |
| **P1** | **Post-Switch "Dangerous Enter" Cooldown Guard** | Intercepts `Return`/`Enter` for `400 ms` right after a gaze focus jump via optional `CGEventTap`, requiring confirmation before executing destructive shell commands. | Medium-High (requires Input Monitoring TCC + `CGEventTap` latency care). |
| **P2** | **Implicit Click-Anchor Online Drift Adaptation** | Uses occasional manual mouse clicks (`leftMouseDown`) as soft calibration updates to compensate for posture slump across a workday without re-running the wizard. | Medium (outlier filtering needed so accidental clicks never corrupt calibration). |
| **P2** | **Persistent Subtle Corner Glow & Hold-to-Peek Reticle** | Always-on hairline border on the active terminal + holding a modifier (`Fn` or `Opt+G`) displays a live gaze reticle for instant aiming confidence. | Low-Medium (`NSPanel` tracking `kAXMovedNotification` / `AXObserver`). |
| **P2** | **Auto-Switch Camera Host on Lid Close / Continuity Cam** | Detects `AVCaptureDevice.wasConnectedNotification` + lid state (`IOPM` / `CGDisplayIsBuiltin` removal) to shift `CameraBezelAnchor` to external monitor automatically. | Low-Medium. |
| **P3** | **Global Push-to-Focus / Pause Hotkey** | Carbon `RegisterEventHotKey` (`Ctrl+Opt+Space`) to pause/resume or "focus only while holding key". | Low. |

---

## 7. Acceptance Criteria & Verification Matrix (`iFocusCoreTests`)

Every module must be verified via `import Testing` (`@Suite` / `@Test` / `#expect`) with zero flaky sleeps:
1. **`CoordinateTransformTests`:** Unequal-height monitors (for example, `1512x982` primary + `-2560x-458..1440` left 4K + `1512x-200..1080` right monitor): round-trip Quartz <-> AppKit exact to `< 1e-6`, `CGDisplayScreenSize <= 1` fallback DPI verified, `CameraBezelAnchor` physical coordinates verified.
2. **`OneEuroFilterTests`:** White-noise stationary gaze (`sigma = 45 pt`) attenuated by `> 60%` RMS while `1800 pt` step saccade settles within `< 180 ms`; `dt = 0`, negative `dt`, and `dt = 2.0 s` gap reset produce finite outputs.
3. **`CalibrationSolverTests`:** Synthetic dual-monitor ground-truth with camera tilt (`15°`), non-zero head translation, and asymmetric eye gain achieves `< 20 pt` mean RMSE with Ridge Regression; collinear points, `< 5` samples, and `NaN` inputs trigger safe rank step-down or structured error without crashing or returning `NaN`.
4. **`AXWindowMatcherTests`:** 5 terminal windows sharing **one PID (`Terminal.app`)** distributed across Left Monitor (`top-left`, `bottom-left`), Right Monitor (`top-right`, `bottom-right`), and an overlapping occluded terminal sharing identical bounds -> matches exact target `AXUIElement` index cleanly with `IoU` + title tie-break; minimized windows excluded.
5. **`FocusDecisionEngineTests`:**
   - *4-5 Terminal Cross-Monitor Switch:* Dwell `220 ms` on Right-Monitor Terminal #4 switches focus from Left-Monitor Terminal #1 without moving cursor.
   - *Typing-Lock Freeze:* Keypress `0.3 s` prior holds focus on Terminal #1 even while gaze rests on Terminal #4 for `1.0 s`; after typing gap `> 0.9 s` + fresh dwell, switches cleanly.
   - *Look-Down-At-Keyboard Guard:* `pitch = +0.40 rad` suppresses switch even when gaze lands over a lower window.
   - *Saccade Flyover & Border Margin:* `2500 pt/s` sweep across 3 intermediate windows triggers 0 switches; `±12 pt` jitter inside sticky margin triggers 0 ping-pong switches.
   - *Secure Input & Manual Mouse Override:* `isSecureInputEnabled == true` or recent `mouseMoved` blocks switch.
6. **`CalibrationStoreTests`:** Saves & reloads topology-keyed calibration profile; verifies POSIX `0600` file permissions and rejection of symlink / `..` traversal paths.
