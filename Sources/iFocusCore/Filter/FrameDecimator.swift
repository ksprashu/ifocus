import Foundation

public struct FrameDecimator: Sendable, Equatable {
    public let targetFPS: Int
    private var nextDue: TimeInterval?

    public init(targetFPS: Int) {
        self.targetFPS = min(max(targetFPS, 5), 30)
    }

    public mutating func reset() {
        nextDue = nil
    }

    public mutating func shouldProcess(at now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        let interval = 1.0 / Double(targetFPS)
        guard let due = nextDue else {
            nextDue = now + interval
            return true
        }
        if (now - due) > 0.25 {
            nextDue = now + interval
            return true
        }
        if (now + 0.005) >= due {
            nextDue = due + interval
            return true
        }
        return false
    }
}
