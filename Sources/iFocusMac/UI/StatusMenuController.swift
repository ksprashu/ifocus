import AppKit
import Foundation
import iFocusCore

@MainActor
public final class StatusMenuController: NSObject {
    public struct Actions {
        public var onToggleEnabled: () -> Void
        public var onCalibrate: () -> Void
        public var onOpenConfigFolder: () -> Void
        public var onOpenPrivacySettings: () -> Void
        public var onQuit: () -> Void

        public init(
            onToggleEnabled: @escaping () -> Void,
            onCalibrate: @escaping () -> Void,
            onOpenConfigFolder: @escaping () -> Void,
            onOpenPrivacySettings: @escaping () -> Void,
            onQuit: @escaping () -> Void
        ) {
            self.onToggleEnabled = onToggleEnabled
            self.onCalibrate = onCalibrate
            self.onOpenConfigFolder = onOpenConfigFolder
            self.onOpenPrivacySettings = onOpenPrivacySettings
            self.onQuit = onQuit
        }
    }

    private struct RenderedState: Equatable {
        var status: CoordinatorStatus
        var warning: String?
    }

    private let statusItem: NSStatusItem
    private let toggleItem: NSMenuItem
    private let stateItem: NSMenuItem
    private let vetoItem: NSMenuItem
    private let failureItem: NSMenuItem
    private let warningItem: NSMenuItem
    private let actions: Actions

    private var lastRendered: RenderedState?
    private var lastIconPaused: Bool?

    public init(actions: Actions) {
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.toggleItem = NSMenuItem(title: "Enabled", action: nil, keyEquivalent: "")
        self.stateItem = NSMenuItem(title: "State: Starting", action: nil, keyEquivalent: "")
        self.vetoItem = NSMenuItem(title: "Last veto: none", action: nil, keyEquivalent: "")
        self.failureItem = NSMenuItem(title: "Failures: 0", action: nil, keyEquivalent: "")
        self.warningItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        super.init()
        setupMenu()
    }

    private func setupMenu() {
        updateIcon(paused: false)

        let menu = NSMenu()
        toggleItem.target = self
        toggleItem.action = #selector(handleToggle)
        toggleItem.state = .on
        menu.addItem(toggleItem)

        stateItem.isEnabled = false
        vetoItem.isEnabled = false
        failureItem.isEnabled = false
        warningItem.isEnabled = false
        warningItem.isHidden = true

        menu.addItem(stateItem)
        menu.addItem(vetoItem)
        menu.addItem(failureItem)
        menu.addItem(warningItem)
        menu.addItem(.separator())

        let calibrateItem = NSMenuItem(title: "Calibrate...", action: #selector(handleCalibrate), keyEquivalent: "")
        calibrateItem.target = self
        menu.addItem(calibrateItem)

        let configItem = NSMenuItem(title: "Open Config Folder", action: #selector(handleOpenConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        let privacyItem = NSMenuItem(title: "Open Privacy Settings", action: #selector(handleOpenPrivacy), keyEquivalent: "")
        privacyItem.target = self
        menu.addItem(privacyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit iFocus", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    public func update(status: CoordinatorStatus, warning: String?) {
        let next = RenderedState(status: status, warning: warning)
        guard next != lastRendered else { return }
        lastRendered = next

        let isPaused = (status.state == .paused)
        toggleItem.state = isPaused ? .off : .on
        toggleItem.title = isPaused ? "Paused (Click to Enable)" : "Enabled"
        updateIcon(paused: isPaused)

        let stateLabel: String
        switch status.state {
        case .running:
            stateLabel = (status.lastVeto == .typing) ? "Waiting for input to go quiet" : "Running"
        case .paused: stateLabel = "Paused"
        case .needsPermission: stateLabel = "Needs Permission"
        case .needsCalibration: stateLabel = "Needs Calibration"
        case .error: stateLabel = "Error\(status.detail.map { ": \($0)" } ?? "")"
        }
        stateItem.title = "State: \(stateLabel)"
        if let detail = status.detail, status.state != .error {
            vetoItem.title = "Last veto: \(status.lastVeto?.rawValue ?? "none") (\(detail))"
        } else {
            vetoItem.title = "Last veto: \(status.lastVeto?.rawValue ?? "none")"
        }
        failureItem.title = "Failures: \(status.failureCount)"

        if let warning, !warning.isEmpty {
            warningItem.title = "Warning: \(warning)"
            warningItem.isHidden = false
        } else {
            warningItem.isHidden = true
        }
    }

    private func updateIcon(paused: Bool) {
        guard lastIconPaused != paused else { return }
        lastIconPaused = paused
        guard let button = statusItem.button else { return }
        let symbolName = paused ? "eye.slash" : "eye"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "iFocus") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.title = paused ? "iF*" : "iF"
        }
    }

    @objc private func handleToggle() {
        actions.onToggleEnabled()
    }

    @objc private func handleCalibrate() {
        actions.onCalibrate()
    }

    @objc private func handleOpenConfig() {
        actions.onOpenConfigFolder()
    }

    @objc private func handleOpenPrivacy() {
        actions.onOpenPrivacySettings()
    }

    @objc private func handleQuit() {
        actions.onQuit()
    }
}
