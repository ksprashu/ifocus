import AppKit
import CoreGraphics
import Foundation
import iFocusCore

@MainActor
public final class HUDController {
    private final class BorderView: NSView {
        var borderColor: NSColor = .controlAccentColor {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let lineWidth: CGFloat = 3.0
            let insetRect = bounds.insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5)
            guard insetRect.width > 0, insetRect.height > 0 else { return }
            let path = NSBezierPath(roundedRect: insetRect, xRadius: 8, yRadius: 8)
            path.lineWidth = lineWidth
            borderColor.withAlphaComponent(0.92).setStroke()
            path.stroke()
        }
    }

    private final class NonActivatingHUDPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let panel: NonActivatingHUDPanel
    private let borderView: BorderView
    private var fadeTask: Task<Void, Never>?

    public init() {
        let panel = NonActivatingHUDPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = BorderView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        self.panel = panel
        self.borderView = view
    }

    public func flashSwitch(windowBoundsQuartz: CGRect, primaryHeight: CGFloat) {
        flash(windowBoundsQuartz: windowBoundsQuartz, primaryHeight: primaryHeight, color: .controlAccentColor)
    }

    public func hide() {
        fadeTask?.cancel()
        fadeTask = nil
        panel.orderOut(nil)
    }

    private func flash(windowBoundsQuartz: CGRect, primaryHeight: CGFloat, color: NSColor) {
        fadeTask?.cancel()

        let cocoaFrame = CoordinateSpace.cocoaRect(fromQuartz: windowBoundsQuartz, primaryHeight: primaryHeight)
        guard cocoaFrame.width > 4, cocoaFrame.height > 4 else { return }

        borderView.borderColor = color
        borderView.frame = CGRect(origin: .zero, size: cocoaFrame.size)
        panel.setFrame(cocoaFrame, display: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1.0
        }
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            panel.animator().alphaValue = 0.0
        }

        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }
}
