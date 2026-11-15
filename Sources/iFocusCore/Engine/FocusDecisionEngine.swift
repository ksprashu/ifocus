import CoreGraphics
import Foundation

public struct FocusDecisionEngine: Sendable {
    private struct PendingCandidate: Sendable, Equatable {
        var target: WindowDescriptor
        var enteredAt: TimeInterval
        var lastSeenAt: TimeInterval
    }

    public var config: Config
    private let policy: any SafetyGuardPolicy

    private var pending: PendingCandidate?
    private var challenger: PendingCandidate?
    public private(set) var lastSwitchAt: TimeInterval?
    public private(set) var lastFailureAt: TimeInterval?
    public private(set) var failureCount: Int = 0
    private var mruEligibleByDisplay: [String: UInt32] = [:]

    public init(config: Config, policy: any SafetyGuardPolicy = DefaultSafetyGuardPolicy()) {
        self.config = config
        self.policy = policy
    }

    public mutating func step(_ input: EngineInput) -> EngineOutput {
        // 1. Reconcile focused window and MRU per display.
        let focused: WindowDescriptor? = input.snapshot.focusedWindowID.flatMap { input.snapshot.window(id: $0) }
        if let focused, WindowHitTester.isEligible(focused, config: config) {
            if let display = input.topology.display(bestFor: focused.bounds) {
                mruEligibleByDisplay[display.uuid] = focused.windowID
            }
        }
        if let focusedID = input.snapshot.focusedWindowID {
            if pending?.target.windowID == focusedID {
                pending = nil
                challenger = nil
            } else if challenger?.target.windowID == focusedID {
                challenger = nil
            }
        }

        // 2. Evaluate safety policy on every step.
        let promptVisible = WindowHitTester.securityPromptVisible(in: input.snapshot)
        let safetyContext = SafetyContext(
            now: input.now,
            isPaused: input.isPaused,
            isSessionActive: input.isSessionActive,
            input: input.input,
            gaze: input.gaze,
            faceCount: input.faceCount,
            headPitch: input.headPitch,
            pitchDownLimit: input.pitchDownLimit,
            frontmostBundleID: input.snapshot.frontmostBundleID,
            lastSwitchAt: lastSwitchAt,
            lastFailureAt: lastFailureAt,
            config: config,
            securityPromptVisible: promptVisible
        )

        var holdVeto: SafetyVeto?
        switch policy.evaluate(safetyContext) {
        case .allow:
            break
        case .deny(let veto):
            switch veto.disposition {
            case .clear:
                pending = nil
                challenger = nil
                return EngineOutput(action: .none, veto: veto, candidateWindowID: nil, dwellProgress: 0)
            case .dropout:
                expireDroppedCandidates(at: input.now)
                return EngineOutput(
                    action: .none,
                    veto: veto,
                    candidateWindowID: pending?.target.windowID,
                    dwellProgress: dwellProgress(for: pending, focused: focused, topology: input.topology, now: input.now)
                )
            case .hold:
                holdVeto = veto
            }
        }

        // 3 & 4. Resolve target and apply hysteresis.
        guard let target = resolveTarget(input: input, focused: focused) else {
            // 5. No target behaves like a dropout sample.
            expireDroppedCandidates(at: input.now)
            return EngineOutput(
                action: .none,
                veto: holdVeto,
                candidateWindowID: pending?.target.windowID,
                dwellProgress: dwellProgress(for: pending, focused: focused, topology: input.topology, now: input.now)
            )
        }

        // 6. Target matches no active pending candidate.
        guard var activePending = pending else {
            pending = PendingCandidate(target: target, enteredAt: input.now, lastSeenAt: input.now)
            challenger = nil
            return EngineOutput(
                action: .none,
                veto: holdVeto,
                candidateWindowID: target.windowID,
                dwellProgress: 0
            )
        }

        // 7. Target differs from pending: apply TRG-10 challenger / anti-starvation logic.
        if activePending.target.windowID != target.windowID {
            if (input.now - activePending.lastSeenAt) > config.candidateDropoutSeconds {
                // Pending expired: promote matching fresh challenger (keeping its enteredAt) or start fresh.
                if let ch = challenger,
                   ch.target.windowID == target.windowID,
                   (input.now - ch.lastSeenAt) <= config.candidateDropoutSeconds {
                    pending = PendingCandidate(target: target, enteredAt: ch.enteredAt, lastSeenAt: input.now)
                } else {
                    pending = PendingCandidate(target: target, enteredAt: input.now, lastSeenAt: input.now)
                }
                challenger = nil
                return evaluatePendingCommit(
                    focused: focused,
                    topology: input.topology,
                    now: input.now,
                    holdVeto: holdVeto,
                    allowFirstSampleCommit: false
                )
            } else {
                // Pending stays alive; record/refresh challenger.
                if var ch = challenger, ch.target.windowID == target.windowID {
                    ch.target = target
                    ch.lastSeenAt = input.now
                    challenger = ch
                } else {
                    challenger = PendingCandidate(target: target, enteredAt: input.now, lastSeenAt: input.now)
                }
                return EngineOutput(
                    action: .none,
                    veto: holdVeto,
                    candidateWindowID: activePending.target.windowID,
                    dwellProgress: dwellProgress(for: activePending, focused: focused, topology: input.topology, now: input.now)
                )
            }
        }

        // 8. Sample landed on pending's target.
        activePending.target = target
        activePending.lastSeenAt = input.now
        pending = activePending

        if let ch = challenger, (input.now - ch.lastSeenAt) > config.candidateDropoutSeconds {
            challenger = nil
        }

        return evaluatePendingCommit(
            focused: focused,
            topology: input.topology,
            now: input.now,
            holdVeto: holdVeto,
            allowFirstSampleCommit: true
        )
    }

    public func confirm(_ target: WindowDescriptor, with input: EngineInput) -> Bool {
        let promptVisible = WindowHitTester.securityPromptVisible(in: input.snapshot)
        let safetyContext = SafetyContext(
            now: input.now,
            isPaused: input.isPaused,
            isSessionActive: input.isSessionActive,
            input: input.input,
            gaze: input.gaze,
            faceCount: input.faceCount,
            headPitch: input.headPitch,
            pitchDownLimit: input.pitchDownLimit,
            frontmostBundleID: input.snapshot.frontmostBundleID,
            lastSwitchAt: lastSwitchAt,
            lastFailureAt: lastFailureAt,
            config: config,
            securityPromptVisible: promptVisible
        )
        guard case .allow = policy.evaluate(safetyContext) else {
            return false
        }
        guard let freshTarget = input.snapshot.window(id: target.windowID),
              freshTarget.pid == target.pid else {
            return false
        }
        let focused = input.snapshot.focusedWindowID.flatMap { input.snapshot.window(id: $0) }
        guard let resolved = resolveTarget(input: input, focused: focused) else {
            return false
        }
        return resolved.windowID == target.windowID
    }

    public mutating func recordOutcome(_ outcome: FocusOutcome, at now: TimeInterval) {
        switch outcome {
        case .switched:
            lastSwitchAt = now
        case .failed:
            lastFailureAt = now
            failureCount += 1
        case .alreadyFocused:
            break
        }
    }

    private mutating func expireDroppedCandidates(at now: TimeInterval) {
        if let currentPending = pending,
           (now - currentPending.lastSeenAt) > config.candidateDropoutSeconds {
            pending = nil
        }
        if let currentChallenger = challenger,
           (now - currentChallenger.lastSeenAt) > config.candidateDropoutSeconds {
            challenger = nil
        }
    }

    private mutating func evaluatePendingCommit(
        focused: WindowDescriptor?,
        topology: DisplayTopology,
        now: TimeInterval,
        holdVeto: SafetyVeto?,
        allowFirstSampleCommit: Bool
    ) -> EngineOutput {
        guard let activePending = pending else {
            return EngineOutput(action: .none, veto: holdVeto, candidateWindowID: nil, dwellProgress: 0)
        }
        let target = activePending.target
        let required = requiredDwell(for: target, focused: focused, topology: topology)
        let elapsed = now - activePending.enteredAt
        let progress = required > 0 ? min(max(elapsed / required, 0), 1) : 1

        if (elapsed + 1e-9) < required || (allowFirstSampleCommit == false && elapsed == 0) {
            return EngineOutput(
                action: .none,
                veto: holdVeto,
                candidateWindowID: target.windowID,
                dwellProgress: progress
            )
        }

        // Do not commit while a challenger candidate is live.
        if challenger != nil {
            return EngineOutput(
                action: .none,
                veto: holdVeto,
                candidateWindowID: target.windowID,
                dwellProgress: progress
            )
        }

        switch holdVeto {
        case nil:
            pending = nil
            challenger = nil
            return EngineOutput(
                action: .focus(target),
                veto: nil,
                candidateWindowID: target.windowID,
                dwellProgress: 1.0
            )
        case .some(let veto):
            return EngineOutput(
                action: .none,
                veto: veto,
                candidateWindowID: target.windowID,
                dwellProgress: 1.0
            )
        }
    }

    private func resolveTarget(input: EngineInput, focused: WindowDescriptor?) -> WindowDescriptor? {
        guard case .point(let gazePoint) = input.gaze else {
            return nil
        }

        let hit = WindowHitTester.hitTest(gazePoint.point, in: input.snapshot, config: config)
        let candidate: WindowDescriptor?
        switch hit {
        case .window(let w):
            candidate = w
        case .blocked:
            candidate = nil
        case .none:
            if config.displayFallback {
                let focusedDisplayUUID = focused.flatMap { input.topology.display(bestFor: $0.bounds)?.uuid }
                if gazePoint.displayUUID != focusedDisplayUUID,
                   let mruID = mruEligibleByDisplay[gazePoint.displayUUID],
                   let mruWindow = input.snapshot.window(id: mruID),
                   WindowHitTester.isEligible(mruWindow, config: config) {
                    candidate = mruWindow
                } else {
                    candidate = nil
                }
            } else {
                candidate = nil
            }
        }

        guard let target = candidate else {
            return nil
        }
        if target.windowID == input.snapshot.focusedWindowID {
            return nil
        }

        if let focused {
            let targetDisplayUUID = input.topology.display(bestFor: target.bounds)?.uuid
            let focusedDisplayUUID = input.topology.display(bestFor: focused.bounds)?.uuid
            if let targetDisplayUUID, targetDisplayUUID == focusedDisplayUUID {
                let margin = CGFloat(config.stickyMarginPoints)
                let inflated = focused.bounds.insetBy(dx: -margin, dy: -margin)
                if inflated.contains(gazePoint.point) {
                    let frontOverride = (target.zIndex < focused.zIndex) && target.bounds.contains(gazePoint.point)
                    if !frontOverride {
                        return nil
                    }
                }
            }
        }

        return target
    }

    private func requiredDwell(
        for target: WindowDescriptor,
        focused: WindowDescriptor?,
        topology: DisplayTopology
    ) -> TimeInterval {
        guard let focused else {
            return config.dwellCrossDisplaySeconds
        }
        let targetDisplayUUID = topology.display(bestFor: target.bounds)?.uuid
        let focusedDisplayUUID = topology.display(bestFor: focused.bounds)?.uuid
        if targetDisplayUUID == nil || focusedDisplayUUID == nil || targetDisplayUUID != focusedDisplayUUID {
            return config.dwellCrossDisplaySeconds
        }
        return config.dwellSameDisplaySeconds
    }

    private func dwellProgress(
        for pending: PendingCandidate?,
        focused: WindowDescriptor?,
        topology: DisplayTopology,
        now: TimeInterval
    ) -> Double {
        guard let pending else { return 0 }
        let required = requiredDwell(for: pending.target, focused: focused, topology: topology)
        guard required > 0 else { return 1 }
        return min(max((now - pending.enteredAt) / required, 0), 1)
    }
}
