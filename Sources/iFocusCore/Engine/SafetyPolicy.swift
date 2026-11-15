import Foundation

public struct DefaultSafetyGuardPolicy: SafetyGuardPolicy, Sendable {
    public init() {}

    public func evaluate(_ context: SafetyContext) -> SafetyVerdict {
        if context.isPaused {
            return .deny(.paused)
        }
        if !context.isSessionActive {
            return .deny(.sessionInactive)
        }
        if context.config.respectSecureInput && context.input.isSecureInputEnabled {
            return .deny(.secureInput)
        }
        if context.securityPromptVisible {
            return .deny(.sourceNotAllowed)
        }

        let gazePoint: GazePoint
        switch context.gaze {
        case .uncalibrated:
            return .deny(.uncalibrated)
        case .noFace, .offScreen:
            return .deny(.noGaze)
        case .point(let pt):
            gazePoint = pt
        }

        if !gazePoint.timestamp.isFinite || (context.now - gazePoint.timestamp) > context.config.staleSampleSeconds {
            return .deny(.staleGaze)
        }
        if !gazePoint.confidence.isFinite || gazePoint.confidence < context.config.minConfidence {
            return .deny(.lowConfidence)
        }
        if context.faceCount > 1 {
            return .deny(.multipleFaces)
        }
        if context.config.lookDownGuard,
           let pitch = context.headPitch,
           let limit = context.pitchDownLimit,
           pitch.isFinite,
           limit.isFinite,
           pitch > (limit + context.config.lookDownMarginRadians) {
            return .deny(.lookingDown)
        }
        if let front = context.frontmostBundleID, Config.isHardBlocked(front) {
            return .deny(.sourceNotAllowed)
        }
        if context.config.requireAllowedSource && !context.config.isBundleAllowed(context.frontmostBundleID) {
            return .deny(.sourceNotAllowed)
        }

        let pointerMovedRecently = context.config.pointerMoveLockSeconds > 0
            && context.input.secondsSincePointerMove < context.config.pointerMoveLockSeconds
        let pointerClickedRecently = context.config.pointerClickLockSeconds > 0
            && context.input.secondsSincePointerClick < context.config.pointerClickLockSeconds
        if context.input.isPointerButtonDown || pointerMovedRecently || pointerClickedRecently {
            return .deny(.pointerActive)
        }

        if let lastFail = context.lastFailureAt,
           (context.now - lastFail) < context.config.failureBackoffSeconds {
            return .deny(.failureBackoff)
        }
        if context.input.isModifierHeld || context.input.secondsSinceKeyboard < context.config.typingLockSeconds {
            return .deny(.typing)
        }
        if let lastSwitch = context.lastSwitchAt,
           (context.now - lastSwitch) < context.config.switchCooldownSeconds {
            return .deny(.cooldown)
        }

        return .allow
    }
}
