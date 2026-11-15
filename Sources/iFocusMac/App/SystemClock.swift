import Foundation
import iFocusCore

public struct SystemClock: MonotonicClock, Sendable {
    public init() {}

    public func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

public struct SystemSleeper: Sleeper, Sendable {
    public init() {}

    public func sleep(seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanos = UInt64((seconds * 1_000_000_000.0).rounded())
        try? await Task.sleep(nanoseconds: nanos)
    }
}
