import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import iFocusCore

public actor AXActuator: FocusActuator {
    private var usePrivateWindowIDResolver: Bool
    private let perElementTimeoutSeconds: Float = 0.25
    private let enumerationBudgetSeconds: TimeInterval = 0.50

    public init(usePrivateWindowIDResolver: Bool = true) {
        self.usePrivateWindowIDResolver = usePrivateWindowIDResolver
    }

    public func setUsePrivateWindowIDResolver(_ enabled: Bool) {
        self.usePrivateWindowIDResolver = enabled
    }

    public func windows(of pid: Int32) async -> [AXWindowCandidate] {
        guard AXIsProcessTrusted() else { return [] }
        let start = ProcessInfo.processInfo.systemUptime
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, perElementTimeoutSeconds)

        let fetchResult = fetchWindowElements(for: appElement)
        if fetchResult.error == .cannotComplete {
            return []
        }

        var candidates: [AXWindowCandidate] = []
        candidates.reserveCapacity(fetchResult.elements.count)

        for (index, element) in fetchResult.elements.enumerated() {
            if (ProcessInfo.processInfo.systemUptime - start) >= enumerationBudgetSeconds {
                return []
            }
            let wid = AXWindowID.windowID(of: element, usePrivateResolver: usePrivateWindowIDResolver)
            let frameRes = readFrame(of: element)
            if frameRes.error == .cannotComplete {
                return []
            }
            let minRes = readBoolAttribute(element, attribute: kAXMinimizedAttribute as CFString)
            if minRes.error == .cannotComplete {
                return []
            }
            let subRes = readStringAttribute(element, attribute: kAXSubroleAttribute as CFString)
            if subRes.error == .cannotComplete {
                return []
            }

            candidates.append(AXWindowCandidate(
                index: index,
                windowID: wid,
                frame: frameRes.value,
                isMinimized: minRes.value ?? false,
                subrole: subRes.value
            ))
        }
        return candidates
    }

    public func perform(_ step: FocusStep, pid: Int32, window: AXWindowCandidate) async -> FocusStepResult {
        guard AXIsProcessTrusted() else { return .notTrusted }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, perElementTimeoutSeconds)

        let fetchResult = fetchWindowElements(for: appElement)
        if fetchResult.error == .cannotComplete {
            return .refused
        }
        let elements = fetchResult.elements
        guard window.index >= 0, window.index < elements.count else {
            return .staleCandidate
        }
        let targetElement = elements[window.index]

        if let expectedID = window.windowID {
            let currentID = AXWindowID.windowID(of: targetElement, usePrivateResolver: usePrivateWindowIDResolver)
            guard currentID == expectedID else {
                return .staleCandidate
            }
        } else if let expectedFrame = window.frame {
            let currentFrameRes = readFrame(of: targetElement)
            if currentFrameRes.error == .cannotComplete {
                return .refused
            }
            guard let currentFrame = currentFrameRes.value,
                  AXWindowMatcher.edgesWithin(currentFrame, expectedFrame, tolerance: 2.0) else {
                return .staleCandidate
            }
        } else {
            return .staleCandidate
        }

        switch step {
        case .raiseAndMakeMain:
            let raiseErr = AXUIElementPerformAction(targetElement, kAXRaiseAction as CFString)
            if raiseErr == .cannotComplete { return .refused }
            let mainErr = AXUIElementSetAttributeValue(targetElement, kAXMainAttribute as CFString, kCFBooleanTrue)
            if mainErr == .cannotComplete { return .refused }
            // Tolerate unsupported kAXFocusedAttribute on terminal windows, but trip circuit breaker on .cannotComplete.
            let focusErr = AXUIElementSetAttributeValue(targetElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if focusErr == .cannotComplete { return .refused }
            return .performed

        case .setAppFrontmost:
            let err = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            return err == .cannotComplete ? .refused : .performed

        case .activateApp:
            let activated = await MainActor.run {
                NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false
            }
            return activated ? .performed : .refused
        }
    }

    public func keyWindowCheck(pid: Int32, expected: AXWindowCandidate) async -> KeyWindowCheck {
        guard AXIsProcessTrusted() else { return .unknown }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, perElementTimeoutSeconds)

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard err == .success,
              let cfVal = value,
              CFGetTypeID(cfVal) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let focusedElement = unsafeDowncast(cfVal, to: AXUIElement.self)
        // RB6: enforce messaging timeout on kAXFocusedWindowAttribute child element as well.
        AXUIElementSetMessagingTimeout(focusedElement, perElementTimeoutSeconds)

        if let expectedID = expected.windowID,
           let focusedID = AXWindowID.windowID(of: focusedElement, usePrivateResolver: usePrivateWindowIDResolver) {
            return focusedID == expectedID ? .matches : .differs
        }
        if let expectedFrame = expected.frame,
           let focusedFrame = readFrame(of: focusedElement).value {
            return AXWindowMatcher.edgesWithin(focusedFrame, expectedFrame, tolerance: 2.0) ? .matches : .differs
        }
        return .unknown
    }

    private func fetchWindowElements(for appElement: AXUIElement) -> (elements: [AXUIElement], error: AXError) {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let array = value as? [AXUIElement] else {
            return ([], err)
        }
        for element in array {
            AXUIElementSetMessagingTimeout(element, perElementTimeoutSeconds)
        }
        return (array, .success)
    }

    private func readFrame(of element: AXUIElement) -> (value: CGRect?, error: AXError) {
        let posRes = readCGPoint(element, attribute: kAXPositionAttribute as CFString)
        if posRes.error == .cannotComplete { return (nil, .cannotComplete) }
        let sizeRes = readCGSize(element, attribute: kAXSizeAttribute as CFString)
        if sizeRes.error == .cannotComplete { return (nil, .cannotComplete) }
        guard let pos = posRes.value, let size = sizeRes.value else {
            return (nil, posRes.error != .success ? posRes.error : sizeRes.error)
        }
        return (CGRect(origin: pos, size: size), .success)
    }

    private func readCGPoint(_ element: AXUIElement, attribute: CFString) -> (value: CGPoint?, error: AXError) {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success,
              let cfVal = value,
              CFGetTypeID(cfVal) == AXValueGetTypeID() else {
            return (nil, err)
        }
        let axValue = unsafeDowncast(cfVal, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return (nil, .failure) }
        var pt = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &pt) else { return (nil, .failure) }
        return (pt, .success)
    }

    private func readCGSize(_ element: AXUIElement, attribute: CFString) -> (value: CGSize?, error: AXError) {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success,
              let cfVal = value,
              CFGetTypeID(cfVal) == AXValueGetTypeID() else {
            return (nil, err)
        }
        let axValue = unsafeDowncast(cfVal, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return (nil, .failure) }
        var sz = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &sz) else { return (nil, .failure) }
        return (sz, .success)
    }

    private func readBoolAttribute(_ element: AXUIElement, attribute: CFString) -> (value: Bool?, error: AXError) {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success, let num = value as? NSNumber else {
            return (nil, err)
        }
        return (num.boolValue, .success)
    }

    private func readStringAttribute(_ element: AXUIElement, attribute: CFString) -> (value: String?, error: AXError) {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success, let str = value as? String else {
            return (nil, err)
        }
        return (str, .success)
    }
}

public struct TrustedFocusSwitcher: FocusSwitcher, Sendable {
    private let ladder: LadderFocusSwitcher

    public init(ladder: LadderFocusSwitcher) {
        self.ladder = ladder
    }

    public func focus(_ target: WindowDescriptor) async -> FocusOutcome {
        guard AXIsProcessTrusted() else {
            return .failed(.notTrusted)
        }
        return await ladder.focus(target)
    }
}
