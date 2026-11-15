import AppKit
import CoreGraphics
import Foundation
import iFocusCore

public enum CalibrationOverlayError: Error, Sendable, CustomStringConvertible {
    case cancelled
    case emptyTopology
    case cameraError(String)
    case calibrationError(CalibrationError)

    public var description: String {
        switch self {
        case .cancelled:
            return "Calibration cancelled"
        case .emptyTopology:
            return "No active displays detected"
        case .cameraError(let msg):
            return msg
        case .calibrationError(let err):
            return err.description
        }
    }
}

@MainActor
public final class CalibrationOverlay: NSObject {
    private final class OverlayWindow: NSWindow {
        var onEscape: (() -> Void)?

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Escape
                onEscape?()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private final class TargetCanvasView: NSView {
        var targetNormalized: CGPoint? {
            didSet { needsDisplay = true }
        }
        var instructionText: String = "" {
            didSet { needsDisplay = true }
        }
        var statusText: String = "" {
            didSet { needsDisplay = true }
        }
        var progressRatio: Double = 0 {
            didSet { needsDisplay = true }
        }
        var isCapturing: Bool = false {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.black.withAlphaComponent(0.72).setFill()
            dirtyRect.fill()

            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let subAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.lightGray,
            ]

            let centerY = bounds.midY + 40
            let titleAttr = NSAttributedString(string: instructionText, attributes: textAttributes)
            let titleSize = titleAttr.size()
            titleAttr.draw(at: NSPoint(x: bounds.midX - titleSize.width * 0.5, y: centerY))

            let statusAttr = NSAttributedString(string: statusText, attributes: subAttributes)
            let statusSize = statusAttr.size()
            statusAttr.draw(at: NSPoint(x: bounds.midX - statusSize.width * 0.5, y: centerY - 34))

            if let norm = targetNormalized {
                // Target coordinates are top-left normalised (u, v); AppKit window content is bottom-left.
                let px = norm.x * bounds.width
                let py = (1.0 - norm.y) * bounds.height
                let outerRadius: CGFloat = isCapturing ? 24 : 20
                let ringRect = NSRect(
                    x: px - outerRadius,
                    y: py - outerRadius,
                    width: outerRadius * 2,
                    height: outerRadius * 2
                )
                let ringPath = NSBezierPath(ovalIn: ringRect)
                ringPath.lineWidth = 3.5
                (isCapturing ? NSColor.systemGreen : NSColor.systemYellow).setStroke()
                ringPath.stroke()

                if isCapturing && progressRatio > 0 {
                    let arcPath = NSBezierPath()
                    let startAngle: CGFloat = 90
                    let endAngle: CGFloat = 90 - CGFloat(min(max(progressRatio, 0), 1) * 360.0)
                    arcPath.appendArc(
                        withCenter: NSPoint(x: px, y: py),
                        radius: outerRadius + 6,
                        startAngle: startAngle,
                        endAngle: endAngle,
                        clockwise: true
                    )
                    arcPath.lineWidth = 3.0
                    NSColor.white.setStroke()
                    arcPath.stroke()
                }

                let innerRadius: CGFloat = 6
                let dotRect = NSRect(
                    x: px - innerRadius,
                    y: py - innerRadius,
                    width: innerRadius * 2,
                    height: innerRadius * 2
                )
                NSColor.white.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
        }
    }

    private var windowsByUUID: [String: (window: OverlayWindow, view: TargetCanvasView)] = [:]
    private var cancelled = false
    private var watchedStream: WatchedStream<GazeEvent>?
    private var activeEstimator: VisionGazeEstimator?

    public override init() {
        super.init()
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        watchedStream?.cancel()
        watchedStream = nil
        teardownWindows()
        if let estimator = activeEstimator {
            Task {
                await estimator.stop()
            }
        }
    }

    public func run(
        topology: DisplayTopology,
        gazeEstimator: VisionGazeEstimator,
        config: Config,
        clock: any MonotonicClock
    ) async -> Result<CalibrationProfile, CalibrationOverlayError> {
        let plan = CalibrationPlan.standard(for: topology)
        guard !plan.isEmpty else {
            return .failure(.emptyTopology)
        }

        cancelled = false
        activeEstimator = gazeEstimator
        setupWindows(for: topology)
        defer {
            watchedStream?.cancel()
            watchedStream = nil
            activeEstimator = nil
            teardownWindows()
        }

        let rawStream: AsyncStream<GazeEvent>
        do {
            rawStream = try await gazeEstimator.start()
        } catch {
            return .failure(.cameraError("\(error)"))
        }

        if cancelled {
            await gazeEstimator.stop()
            return .failure(.cancelled)
        }

        let watched = WatchedStream(
            source: rawStream,
            timeout: 5.0,
            clock: clock,
            sleeper: SystemSleeper()
        )
        watchedStream = watched

        var session = CalibrationSession(plan: plan, minConfidence: config.minConfidence)
        if let first = session.currentTarget {
            render(target: first, instruction: instruction(for: first), status: "Settling... (Press Esc or click Cancel)", progress: 0, capturing: false)
        }

        for await item in watched.stream {
            if cancelled {
                await gazeEstimator.stop()
                return .failure(.cancelled)
            }

            switch item {
            case .stalled:
                await gazeEstimator.stop()
                return .failure(.cameraError("No camera frames for 5 s"))

            case .event(let event):
                switch event {
                case .noFace:
                    if let current = session.currentTarget {
                        render(target: current, instruction: instruction(for: current), status: "Face not detected — look at the target dot (Esc to cancel)", progress: 0, capturing: false)
                    }
                case .interrupted(let reason):
                    await gazeEstimator.stop()
                    return .failure(.cameraError(reason))
                case .features(let features):
                    let progress = session.ingest(features)
                    switch progress {
                    case .settling(let target, let p):
                        render(target: target, instruction: instruction(for: target), status: "Hold gaze on the dot... (Esc to cancel)", progress: p, capturing: false)
                    case .capturing(let target, let count, let p):
                        render(target: target, instruction: instruction(for: target), status: "Capturing (\(count) samples)... (Esc to cancel)", progress: p, capturing: true)
                    case .repeating(let target, let attempt):
                        render(target: target, instruction: instruction(for: target), status: "Too few samples — repeating target (attempt \(attempt)/3)", progress: 0, capturing: false)
                    case .advanced(let next):
                        render(target: next, instruction: instruction(for: next), status: "Next target...", progress: 0, capturing: false)
                    case .finished:
                        await gazeEstimator.stop()
                        let cameraID = await gazeEstimator.activeCameraUniqueID() ?? "default-camera"
                        switch session.solve(cameraUniqueID: cameraID, createdAt: clock.now(), config: config) {
                        case .success(let profile):
                            return .success(profile)
                        case .failure(let err):
                            return .failure(.calibrationError(err))
                        }
                    case .failed(let err):
                        await gazeEstimator.stop()
                        return .failure(.calibrationError(err))
                    }
                }
            }
        }

        await gazeEstimator.stop()
        if cancelled {
            return .failure(.cancelled)
        }
        return .failure(.calibrationError(.insufficientSamples))
    }

    private func setupWindows(for topology: DisplayTopology) {
        let screens = NSScreen.screens
        var screenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                screenByDisplayID[CGDirectDisplayID(num.uint32Value)] = screen
            }
        }

        for display in topology.displays {
            guard let screen = screenByDisplayID[CGDirectDisplayID(display.id)] else { continue }
            let win = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.level = .screenSaver
            win.isOpaque = false
            win.backgroundColor = .clear
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.onEscape = { [weak self] in
                self?.cancel()
            }

            let canvas = TargetCanvasView(frame: CGRect(origin: .zero, size: screen.frame.size))
            canvas.autoresizingMask = [.width, .height]

            let cancelButton = NSButton(
                title: "Cancel (Esc)",
                target: self,
                action: #selector(handleCancelButton)
            )
            cancelButton.bezelStyle = .rounded
            cancelButton.frame = NSRect(
                x: (canvas.bounds.width - 140) * 0.5,
                y: max(48, canvas.bounds.midY - 120),
                width: 140,
                height: 32
            )
            cancelButton.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            canvas.addSubview(cancelButton)

            win.contentView = canvas
            win.makeKeyAndOrderFront(nil)
            windowsByUUID[display.uuid] = (win, canvas)
        }
        NSApp.activate()
    }

    @objc private func handleCancelButton() {
        cancel()
    }

    private func teardownWindows() {
        for (_, pair) in windowsByUUID {
            pair.window.orderOut(nil)
        }
        windowsByUUID.removeAll()
    }

    private func render(
        target: CalibrationTarget,
        instruction: String,
        status: String,
        progress: Double,
        capturing: Bool
    ) {
        for (uuid, pair) in windowsByUUID {
            if uuid == target.displayUUID {
                pair.view.targetNormalized = CGPoint(x: target.u, y: target.v)
                pair.view.instructionText = instruction
                pair.view.statusText = status
                pair.view.progressRatio = progress
                pair.view.isCapturing = capturing
            } else {
                pair.view.targetNormalized = nil
                pair.view.instructionText = "Look at the highlighted target on the active display"
                pair.view.statusText = "Press Esc or click Cancel"
                pair.view.progressRatio = 0
                pair.view.isCapturing = false
            }
        }
    }

    private func instruction(for target: CalibrationTarget) -> String {
        switch target.pass {
        case .natural:
            return "Look naturally at the target dot"
        case .eyesOnly:
            return "Keep your head facing the centre — move only your eyes"
        }
    }
}
