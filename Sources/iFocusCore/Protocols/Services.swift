import Foundation

public protocol GazeEstimator: Sendable {
    func start() async throws -> AsyncStream<GazeEvent>
    func stop() async
}

public protocol DisplayTopologyService: Sendable {
    func current() async -> DisplayTopology
    func updates() -> AsyncStream<DisplayTopology>
}

public protocol WindowCatalogService: Sendable {
    func snapshot() async -> WindowSnapshot
}

public protocol InputActivityProvider: Sendable {
    func sample() -> InputActivity
}

public protocol SessionStateProvider: Sendable {
    func isSessionActive() -> Bool
}

public protocol MonotonicClock: Sendable {
    func now() -> TimeInterval
}

public protocol Sleeper: Sendable {
    func sleep(seconds: TimeInterval) async
}

public protocol FocusSwitcher: Sendable {
    func focus(_ target: WindowDescriptor) async -> FocusOutcome
}

public protocol FocusActuator: Sendable {
    func windows(of pid: Int32) async -> [AXWindowCandidate]
    func perform(_ step: FocusStep, pid: Int32, window: AXWindowCandidate) async -> FocusStepResult
    func keyWindowCheck(pid: Int32, expected: AXWindowCandidate) async -> KeyWindowCheck
}

extension FocusActuator {
    public func keyWindowCheck(pid: Int32, expected: AXWindowCandidate) async -> KeyWindowCheck {
        .unknown
    }
}

public protocol SafetyGuardPolicy: Sendable {
    func evaluate(_ context: SafetyContext) -> SafetyVerdict
}
