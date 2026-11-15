import Carbon.HIToolbox
import CoreGraphics
import Foundation
import iFocusCore

public struct SystemInputActivityProvider: InputActivityProvider, Sendable {
    public init() {}

    public func sample() -> InputActivity {
        let state: CGEventSourceStateID = .combinedSessionState

        let sinceKeyDown = CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown)
        let sinceKeyUp = CGEventSource.secondsSinceLastEventType(state, eventType: .keyUp)
        let sinceFlagsChanged = CGEventSource.secondsSinceLastEventType(state, eventType: .flagsChanged)
        let secondsSinceKeyboard = min(sinceKeyDown, min(sinceKeyUp, sinceFlagsChanged))

        let rawFlags = CGEventSource.flagsState(state)
        let watchedModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        let isModifierHeld = !rawFlags.intersection(watchedModifiers).isEmpty

        let secondsSincePointerMove = CGEventSource.secondsSinceLastEventType(state, eventType: .mouseMoved)

        let sinceLeftDown = CGEventSource.secondsSinceLastEventType(state, eventType: .leftMouseDown)
        let sinceRightDown = CGEventSource.secondsSinceLastEventType(state, eventType: .rightMouseDown)
        let sinceOtherDown = CGEventSource.secondsSinceLastEventType(state, eventType: .otherMouseDown)
        let sinceLeftUp = CGEventSource.secondsSinceLastEventType(state, eventType: .leftMouseUp)
        let sinceRightUp = CGEventSource.secondsSinceLastEventType(state, eventType: .rightMouseUp)
        let sinceOtherUp = CGEventSource.secondsSinceLastEventType(state, eventType: .otherMouseUp)
        let sinceLeftDrag = CGEventSource.secondsSinceLastEventType(state, eventType: .leftMouseDragged)
        let sinceRightDrag = CGEventSource.secondsSinceLastEventType(state, eventType: .rightMouseDragged)
        let sinceOtherDrag = CGEventSource.secondsSinceLastEventType(state, eventType: .otherMouseDragged)
        let sinceScroll = CGEventSource.secondsSinceLastEventType(state, eventType: .scrollWheel)
        let secondsSincePointerClick = min(
            min(min(sinceLeftDown, sinceRightDown), sinceOtherDown),
            min(
                min(min(sinceLeftUp, sinceRightUp), sinceOtherUp),
                min(min(sinceLeftDrag, sinceRightDrag), min(sinceOtherDrag, sinceScroll))
            )
        )

        let isButtonDown = CGEventSource.buttonState(state, button: .left)
            || CGEventSource.buttonState(state, button: .right)
            || CGEventSource.buttonState(state, button: .center)

        let secureInput = IsSecureEventInputEnabled()

        return InputActivity(
            secondsSinceKeyboard: secondsSinceKeyboard,
            secondsSincePointerMove: secondsSincePointerMove,
            secondsSincePointerClick: secondsSincePointerClick,
            isModifierHeld: isModifierHeld,
            isPointerButtonDown: isButtonDown,
            isSecureInputEnabled: secureInput
        )
    }
}
