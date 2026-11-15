import Foundation

public struct SessionSignals: Sendable, Equatable {
    public var dictionaryAvailable: Bool
    public var onConsole: Bool
    public var screenLocked: Bool
    public var systemSleeping: Bool
    public var displaysSleeping: Bool

    public init(
        dictionaryAvailable: Bool,
        onConsole: Bool = true,
        screenLocked: Bool = false,
        systemSleeping: Bool = false,
        displaysSleeping: Bool = false
    ) {
        self.dictionaryAvailable = dictionaryAvailable
        self.onConsole = onConsole
        self.screenLocked = screenLocked
        self.systemSleeping = systemSleeping
        self.displaysSleeping = displaysSleeping
    }
}

public enum SessionActivity {
    public static func isActive(_ s: SessionSignals) -> Bool {
        s.dictionaryAvailable && s.onConsole && !s.screenLocked && !s.systemSleeping && !s.displaysSleeping
    }
}
