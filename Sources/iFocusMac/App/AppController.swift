import AppKit
import AVFoundation
import Foundation
import os
import iFocusCore

@MainActor
public final class AppController {
    private static let logger = Logger(subsystem: "dev.ifocus.app", category: "coordinator")

    private let configStore = ConfigStore()
    private let profileStore = ProfileStore()
    private var configResult: ConfigLoadResult
    private var profile: CalibrationProfile?
    private var warningBanner: String?

    private let clock = SystemClock()
    private let topologyService = CGDisplayTopologyService()
    private let catalogService = CGWindowCatalogService()
    private let inputProvider = SystemInputActivityProvider()
    private let sessionProvider = SystemSessionStateProvider()
    private let actuator: AXActuator
    private let gazeEstimator: VisionGazeEstimator
    private let coordinator: FocusCoordinator

    private var menuController: StatusMenuController?
    private let hudController = HUDController()
    private var hotKeyController: HotKeyController?
    private var eventLoopTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var cameraConnectedObserver: NSObjectProtocol?
    private var isCalibrating = false
    private var activeCalibrationOverlay: CalibrationOverlay?
    private var lastCoordinatorState: CoordinatorStateKind?

    public static func runCalibrateCommand() -> Int32 {
        guard Permissions.hasCameraUsageDescription() else {
            fputs("Error: NSCameraUsageDescription is missing from Info.plist.\n", stderr)
            return 78
        }

        let sessionProvider = SystemSessionStateProvider()
        sessionProvider.startObserving()
        guard sessionProvider.isSessionActive() else {
            sessionProvider.stopObserving()
            fputs("Error: Cannot calibrate while session is locked or asleep.\n", stderr)
            return 1
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var exitCode: Int32 = 1
        let overlay = CalibrationOverlay()

        let sessionMonitor = Task { @MainActor in
            for await active in sessionProvider.updates() {
                if !active {
                    overlay.cancel()
                    break
                }
            }
        }

        Task { @MainActor in
            defer {
                sessionMonitor.cancel()
                sessionProvider.stopObserving()
                stopAppRunLoop()
            }

            let granted = await Permissions.requestCameraAccessIfNeeded()
            guard granted else {
                fputs("Error: Camera permission is required for calibration.\n", stderr)
                exitCode = 77
                return
            }

            let configResult = ConfigStore().load()
            let config = configResult.config
            let topology = CGDisplayTopologyService.readCurrentSync()
            if topology.displays.isEmpty {
                fputs("Error: No active displays available for calibration.\n", stderr)
                exitCode = 1
                return
            }

            let estimator = VisionGazeEstimator(
                clock: SystemClock(),
                cameraUniqueID: config.cameraUniqueID,
                targetFPS: config.cameraFPS
            )
            let result = await overlay.run(
                topology: topology,
                gazeEstimator: estimator,
                config: config,
                clock: SystemClock()
            )

            switch result {
            case .success(let profile):
                do {
                    try ProfileStore().save(profile)
                    print("Calibration succeeded for \(profile.models.count) display(s):")
                    for (uuid, model) in profile.models.sorted(by: { $0.key < $1.key }) {
                        let warn = model.headBarelyMoved ? " [WARNING: headBarelyMoved]" : ""
                        print("  \(uuid): cross-validation RMS = \(String(format: "%.4f", model.crossValidationError)) (\(model.sampleCount) samples)\(warn)")
                    }
                    exitCode = 0
                } catch {
                    fputs("Error saving calibration profile: \(error)\n", stderr)
                    exitCode = 1
                }
            case .failure(let err):
                fputs("Calibration failed: \(err.description)\n", stderr)
                exitCode = 1
            }
        }

        app.run()
        return exitCode
    }

    public static func runAgentCommand() -> Int32 {
        guard Permissions.hasCameraUsageDescription() else {
            fputs("Error: NSCameraUsageDescription is missing from Info.plist.\n", stderr)
            return 78
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController()
        controller.start()
        app.run()
        return 0
    }

    private init() {
        var loadedCfg = configStore.load()
        loadedCfg.config.excludeBundleIDIfNeeded(Bundle.main.bundleIdentifier)
        self.configResult = loadedCfg
        let cfg = loadedCfg.config

        let estimator = VisionGazeEstimator(
            clock: clock,
            cameraUniqueID: cfg.cameraUniqueID,
            targetFPS: cfg.cameraFPS
        )
        self.gazeEstimator = estimator

        let activeCameraID = cfg.cameraUniqueID ?? CameraSession.resolveDevice(uniqueID: nil)?.uniqueID
        let loadedProfile = profileStore.load(activeCameraUniqueID: activeCameraID)
        self.profile = loadedProfile.profile

        if let cfgErr = loadedCfg.error {
            self.warningBanner = cfgErr
        } else if let profErr = loadedProfile.error {
            self.warningBanner = profErr
        } else if let prof = loadedProfile.profile, prof.models.values.contains(where: \.headBarelyMoved) {
            self.warningBanner = "Head barely moved during calibration — consider recalibrating"
        }

        let axActuator = AXActuator(usePrivateWindowIDResolver: cfg.usePrivateWindowIDResolver)
        self.actuator = axActuator
        let switcher = TrustedFocusSwitcher(
            ladder: LadderFocusSwitcher(
                actuator: axActuator,
                catalog: catalogService,
                sleeper: SystemSleeper(),
                clock: clock
            )
        )

        self.coordinator = FocusCoordinator(
            config: cfg,
            profile: loadedProfile.profile,
            gazeEstimator: estimator,
            topologyService: topologyService,
            windowCatalog: catalogService,
            inputProvider: inputProvider,
            sessionProvider: sessionProvider,
            focusSwitcher: switcher,
            clock: clock,
            permissionChecker: {
                (
                    camera: Permissions.cameraStatus() == .authorized,
                    accessibility: Permissions.isAccessibilityTrusted()
                )
            },
            retrySleeper: SystemSleeper()
        )
    }

    private func start() {
        sessionProvider.startObserving()

        let actions = StatusMenuController.Actions(
            onToggleEnabled: { [weak self] in
                Task { @MainActor in await self?.togglePause() }
            },
            onCalibrate: { [weak self] in
                Task { @MainActor in await self?.runInteractiveCalibration() }
            },
            onOpenConfigFolder: {
                let dir = SecureFileStore.defaultDirectoryURL()
                try? SecureFileStore(directoryURL: dir).ensureDirectoryExists()
                NSWorkspace.shared.open(dir)
            },
            onOpenPrivacySettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            },
            onQuit: { [weak self] in
                Task { @MainActor in
                    await self?.shutdown()
                    Self.stopAppRunLoop()
                }
            }
        )
        let menu = StatusMenuController(actions: actions)
        self.menuController = menu

        let hk = HotKeyController { [weak self] in
            Task { @MainActor in await self?.togglePause() }
        }
        _ = hk.register(spec: configResult.config.pauseHotKey)
        self.hotKeyController = hk

        eventLoopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await coordinator.events()
            for await event in stream {
                await self.handleCoordinatorEvent(event)
            }
        }

        sessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await active in sessionProvider.updates() {
                if active {
                    await self.startTrackingIfReady()
                } else {
                    self.activeCalibrationOverlay?.cancel()
                    await self.coordinator.stop()
                }
            }
        }

        // RB3: restart tracking immediately when a camera reconnects after an error state.
        cameraConnectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let paused = await self.coordinator.paused()
                guard self.lastCoordinatorState == .error, !paused, !self.isCalibrating else { return }
                await self.coordinator.stop()
                await self.startTrackingIfReady()
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await Permissions.requestCameraAccessIfNeeded()
            _ = Permissions.promptAccessibilityIfNeeded()
            await self.startTrackingIfReady()
        }
    }

    private func startTrackingIfReady() async {
        guard !isCalibrating else { return }
        let isPaused = await coordinator.paused()
        let camOK = Permissions.cameraStatus() == .authorized
        let axOK = Permissions.isAccessibilityTrusted()

        if !camOK || !axOK {
            menuController?.update(
                status: CoordinatorStatus(state: .needsPermission, failureCount: await coordinator.failureCount()),
                warning: warningBanner
            )
            return
        }
        if isPaused {
            menuController?.update(
                status: CoordinatorStatus(state: .paused, lastVeto: .paused, failureCount: await coordinator.failureCount()),
                warning: warningBanner
            )
            return
        }
        guard profile != nil else {
            menuController?.update(
                status: CoordinatorStatus(state: .needsCalibration, failureCount: await coordinator.failureCount()),
                warning: warningBanner
            )
            return
        }
        guard sessionProvider.isSessionActive() else {
            return
        }
        await coordinator.start()
    }

    private func togglePause() async {
        let nowPaused = await coordinator.togglePaused()
        Self.logger.info("Coordinator paused=\(nowPaused, privacy: .public)")
        if nowPaused {
            await coordinator.stop()
        } else {
            await startTrackingIfReady()
        }
    }

    private func runInteractiveCalibration() async {
        guard !isCalibrating else { return }
        isCalibrating = true
        let wasPaused = await coordinator.paused()
        defer { isCalibrating = false }

        await coordinator.setPaused(true)
        await coordinator.stop()

        let camOK = await Permissions.requestCameraAccessIfNeeded()
        guard camOK else {
            warningBanner = "Camera permission is required to calibrate"
            await coordinator.setPaused(wasPaused)
            await startTrackingIfReady()
            return
        }

        guard sessionProvider.isSessionActive() else {
            warningBanner = "Cannot calibrate while session is locked or asleep"
            await coordinator.setPaused(wasPaused)
            await startTrackingIfReady()
            return
        }

        let topology = await topologyService.current()
        let overlay = CalibrationOverlay()
        activeCalibrationOverlay = overlay
        let result = await overlay.run(
            topology: topology,
            gazeEstimator: gazeEstimator,
            config: configResult.config,
            clock: clock
        )
        activeCalibrationOverlay = nil

        switch result {
        case .success(let newProfile):
            do {
                try profileStore.save(newProfile)
                profile = newProfile
                await coordinator.updateProfile(newProfile)
                if newProfile.models.values.contains(where: \.headBarelyMoved) {
                    warningBanner = "Head barely moved during calibration — consider recalibrating"
                } else {
                    warningBanner = configResult.error
                }
            } catch {
                warningBanner = "Failed to save calibration: \(error)"
            }
        case .failure(.cancelled):
            break
        case .failure(let err):
            warningBanner = err.description
        }

        await coordinator.setPaused(wasPaused)
        await startTrackingIfReady()
    }

    private func handleCoordinatorEvent(_ event: CoordinatorEvent) async {
        switch event {
        case .status(let status):
            lastCoordinatorState = status.state
            menuController?.update(status: status, warning: warningBanner)
        case .switched(let window, let strategy):
            let wid = window.windowID
            let pid = window.pid
            let bundle = window.bundleID ?? "unknown"
            Self.logger.info("Switched windowID=\(wid) pid=\(pid) bundle=\(bundle, privacy: .public) strategy=\(strategy.rawValue, privacy: .public)")
            if configResult.config.switchFlash {
                let topo = await topologyService.current()
                hudController.flashSwitch(windowBoundsQuartz: window.bounds, primaryHeight: topo.primaryHeight)
            }
        case .failed(let window, let failure):
            let wid = window.windowID
            let pid = window.pid
            let bundle = window.bundleID ?? "unknown"
            Self.logger.warning("Switch failed windowID=\(wid) pid=\(pid) bundle=\(bundle, privacy: .public) reason=\(failure.rawValue, privacy: .public)")
        }
    }

    private func shutdown() async {
        if let observer = cameraConnectedObserver {
            NotificationCenter.default.removeObserver(observer)
            cameraConnectedObserver = nil
        }
        activeCalibrationOverlay?.cancel()
        activeCalibrationOverlay = nil
        eventLoopTask?.cancel()
        sessionTask?.cancel()
        hotKeyController?.unregister()
        hudController.hide()
        sessionProvider.stopObserving()
        await coordinator.stop()
    }

    private static func stopAppRunLoop() {
        NSApp.stop(nil)
        let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
        if let event {
            NSApp.postEvent(event, atStart: true)
        }
    }
}
