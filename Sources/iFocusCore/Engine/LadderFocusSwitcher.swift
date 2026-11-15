import Foundation

public struct LadderFocusSwitcher: FocusSwitcher, Sendable {
    private let actuator: any FocusActuator
    private let catalog: any WindowCatalogService
    private let sleeper: any Sleeper
    private let clock: (any MonotonicClock)?
    private let deadlineSeconds: TimeInterval
    private let verificationDelaySeconds: TimeInterval = 0.05
    private let rollbackDeadlineSeconds: TimeInterval = 0.35

    public init(
        actuator: any FocusActuator,
        catalog: any WindowCatalogService,
        sleeper: any Sleeper,
        clock: (any MonotonicClock)? = nil,
        deadlineSeconds: TimeInterval = 1.0
    ) {
        self.actuator = actuator
        self.catalog = catalog
        self.sleeper = sleeper
        self.clock = clock
        self.deadlineSeconds = deadlineSeconds
    }

    public func focus(_ target: WindowDescriptor) async -> FocusOutcome {
        let startTime = clock?.now()
        let initial = await catalog.snapshot()
        // RC1: requires both frontmost PID and focused window ID to short-circuit.
        if initial.frontmostPID == target.pid && initial.focusedWindowID == target.windowID {
            return .alreadyFocused
        }

        let crossPID = initial.frontmostPID != target.pid
        let rungs: [(FocusStrategy, [FocusStep])] = crossPID
            ? [
                (.rungB, [.raiseAndMakeMain, .setAppFrontmost, .raiseAndMakeMain]),
                (.rungC, [.raiseAndMakeMain, .activateApp, .raiseAndMakeMain]),
            ]
            : [
                (.rungA, [.raiseAndMakeMain]),
                (.rungB, [.raiseAndMakeMain, .setAppFrontmost]),
                (.rungC, [.raiseAndMakeMain, .activateApp]),
            ]
        let verificationAttempts = crossPID ? 8 : 3

        var lastStepOutcome: FocusStepResult = .performed
        var timedOut = false

        for (strategy, steps) in rungs {
            if isPastDeadline(startTime: startTime, limit: deadlineSeconds) {
                timedOut = true
                break
            }

            let candidates = await actuator.windows(of: target.pid)
            if isPastDeadline(startTime: startTime, limit: deadlineSeconds) {
                timedOut = true
                break
            }
            guard var candidate = matchCandidate(target: target, in: candidates) else {
                if candidates.isEmpty {
                    return .failed(.windowNotFound)
                }
                return .failed(.windowNotFound)
            }

            var rungCompleted = true
            for step in steps {
                if isPastDeadline(startTime: startTime, limit: deadlineSeconds) {
                    timedOut = true
                    rungCompleted = false
                    break
                }

                var stepResult = await actuator.perform(step, pid: target.pid, window: candidate)
                lastStepOutcome = stepResult

                if stepResult == .staleCandidate {
                    // One re-match per step when AX reports stale ordering or frame drift.
                    if isPastDeadline(startTime: startTime, limit: deadlineSeconds) {
                        timedOut = true
                        rungCompleted = false
                        break
                    }
                    let refreshed = await actuator.windows(of: target.pid)
                    if isPastDeadline(startTime: startTime, limit: deadlineSeconds) {
                        timedOut = true
                        rungCompleted = false
                        break
                    }
                    guard let freshCandidate = matchCandidate(target: target, in: refreshed) else {
                        rungCompleted = false
                        break
                    }
                    candidate = freshCandidate
                    if isPastDeadline(startTime: startTime, limit: deadlineSeconds) {
                        timedOut = true
                        rungCompleted = false
                        break
                    }
                    stepResult = await actuator.perform(step, pid: target.pid, window: candidate)
                    lastStepOutcome = stepResult
                }

                switch stepResult {
                case .performed:
                    continue
                case .notTrusted:
                    return .failed(.notTrusted)
                case .staleCandidate, .refused:
                    rungCompleted = false
                }
                if !rungCompleted { break }
            }

            if timedOut { break }
            if !rungCompleted { continue }

            let verified = await verifyFocused(
                target: target,
                candidate: candidate,
                attempts: verificationAttempts,
                startTime: startTime,
                timedOut: &timedOut
            )
            if verified {
                return .switched(strategy)
            }
            if timedOut { break }
        }

        if timedOut {
            await rollbackIfNeeded(initial: initial, target: target, timedOut: true)
            return .failed(.timedOut)
        }

        await rollbackIfNeeded(initial: initial, target: target, timedOut: false)
        if lastStepOutcome == .staleCandidate {
            return .failed(.staleCandidate)
        }
        return .failed(.unverified)
    }

    private func matchCandidate(target: WindowDescriptor, in candidates: [AXWindowCandidate]) -> AXWindowCandidate? {
        guard !candidates.isEmpty else { return nil }
        let matchedIndex: Int
        switch AXWindowMatcher.match(target: target, candidates: candidates) {
        case .exact(let idx),
             .geometric(let idx),
             .ambiguous(let idx, _),
             .approximate(let idx):
            matchedIndex = idx
        case .notFound:
            return nil
        }
        return candidates.first(where: { $0.index == matchedIndex })
    }

    private func verifyFocused(
        target: WindowDescriptor,
        candidate: AXWindowCandidate,
        attempts: Int,
        startTime: TimeInterval?,
        timedOut: inout Bool
    ) async -> Bool {
        for attempt in 0..<max(attempts, 1) {
            if isPastDeadline(startTime: startTime, limit: deadlineSeconds) {
                timedOut = true
                return false
            }
            if attempt > 0 {
                await sleeper.sleep(seconds: verificationDelaySeconds)
                if isPastDeadline(startTime: startTime, limit: deadlineSeconds) {
                    timedOut = true
                    return false
                }
            }
            let snap = await catalog.snapshot()
            if snap.frontmostPID == target.pid && snap.focusedWindowID == target.windowID {
                let keyCheck = await actuator.keyWindowCheck(pid: target.pid, expected: candidate)
                if keyCheck != .differs {
                    return true
                }
            }
        }
        return false
    }

    private func rollbackIfNeeded(
        initial: WindowSnapshot,
        target: WindowDescriptor,
        timedOut: Bool
    ) async {
        guard let initialID = initial.focusedWindowID,
              let initialWindow = initial.window(id: initialID) else {
            return
        }
        let current = await catalog.snapshot()
        let isTargetFocused = (current.frontmostPID == target.pid && current.focusedWindowID == target.windowID)
        let isInitialStillFocused = (current.frontmostPID == initial.frontmostPID && current.focusedWindowID == initialID)
        guard !isTargetFocused,
              !isInitialStillFocused,
              current.window(id: initialID) != nil else {
            return
        }
        if timedOut && initialWindow.pid == target.pid {
            return
        }

        let rbStart = clock?.now()
        let candidates = await actuator.windows(of: initialWindow.pid)
        guard !isPastDeadline(startTime: rbStart, limit: rollbackDeadlineSeconds) else { return }

        guard let candidate = matchCandidate(target: initialWindow, in: candidates) else {
            return
        }

        for step in [FocusStep.raiseAndMakeMain, .setAppFrontmost] {
            guard !isPastDeadline(startTime: rbStart, limit: rollbackDeadlineSeconds) else { return }
            _ = await actuator.perform(step, pid: initialWindow.pid, window: candidate)
        }
    }

    private func isPastDeadline(startTime: TimeInterval?, limit: TimeInterval) -> Bool {
        guard let clock, let startTime else { return false }
        return (clock.now() - startTime) >= limit
    }
}
