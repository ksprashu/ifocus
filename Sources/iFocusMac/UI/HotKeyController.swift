import Carbon.HIToolbox
import Foundation

@MainActor
public final class HotKeyController {
    private static weak var activeTrampoline: HotKeyController?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onTrigger: @MainActor () -> Void

    public init(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
    }

    public func register(spec: String) -> Bool {
        unregister()

        let parsed = Self.parse(spec: spec)
        Self.activeTrampoline = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, _ -> OSStatus in
            Task { @MainActor in
                HotKeyController.activeTrampoline?.handlePress()
            }
            return noErr
        }

        let installErr = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        guard installErr == noErr else {
            unregister()
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4946_4F43), id: 1) // 'IFOC'
        let regErr = RegisterEventHotKey(
            parsed.keyCode,
            parsed.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard regErr == noErr else {
            unregister()
            return false
        }

        return true
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if Self.activeTrampoline === self {
            Self.activeTrampoline = nil
        }
    }

    private func handlePress() {
        onTrigger()
    }

    private static func parse(spec: String) -> (keyCode: UInt32, modifiers: UInt32) {
        let parts = spec
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var modifiers: UInt32 = 0
        var keyCode: UInt32 = UInt32(kVK_ANSI_F)

        for part in parts {
            switch part {
            case "ctrl", "control":
                modifiers |= UInt32(controlKey)
            case "opt", "option", "alt":
                modifiers |= UInt32(optionKey)
            case "cmd", "command":
                modifiers |= UInt32(cmdKey)
            case "shift":
                modifiers |= UInt32(shiftKey)
            default:
                if let mapped = keyCodeForToken(part) {
                    keyCode = mapped
                }
            }
        }

        if modifiers == 0 {
            modifiers = UInt32(controlKey | optionKey | cmdKey)
        }
        return (keyCode, modifiers)
    }

    private static func keyCodeForToken(_ token: String) -> UInt32? {
        let table: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "space": kVK_Space,
        ]
        return table[token].map { UInt32($0) }
    }
}
