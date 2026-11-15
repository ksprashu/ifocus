import Foundation

public struct InputActivity: Sendable, Equatable {
    /// Minimum seconds since keyDown, keyUp, or flagsChanged.
    public var secondsSinceKeyboard: TimeInterval
    /// Seconds since mouseMoved.
    public var secondsSincePointerMove: TimeInterval
    /// Minimum seconds since mouseDown, mouseUp, mouseDragged (left/right/other), or scrollWheel.
    public var secondsSincePointerClick: TimeInterval
    /// True while shift, control, option, or command modifier flags are held.
    public var isModifierHeld: Bool
    /// True while left, right, or centre mouse button is held down.
    public var isPointerButtonDown: Bool
    /// True while Secure Keyboard Entry is active.
    public var isSecureInputEnabled: Bool

    public init(
        secondsSinceKeyboard: TimeInterval = 1000,
        secondsSincePointerMove: TimeInterval = 1000,
        secondsSincePointerClick: TimeInterval = 1000,
        isModifierHeld: Bool = false,
        isPointerButtonDown: Bool = false,
        isSecureInputEnabled: Bool = false
    ) {
        self.secondsSinceKeyboard = secondsSinceKeyboard
        self.secondsSincePointerMove = secondsSincePointerMove
        self.secondsSincePointerClick = secondsSincePointerClick
        self.isModifierHeld = isModifierHeld
        self.isPointerButtonDown = isPointerButtonDown
        self.isSecureInputEnabled = isSecureInputEnabled
    }
}
