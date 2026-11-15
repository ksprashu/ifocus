import CoreGraphics
import Foundation

public enum FocusStep: Sendable, Equatable {
    case raiseAndMakeMain
    case setAppFrontmost
    case activateApp
}

public enum FocusStrategy: String, Sendable, Equatable, Codable {
    case rungA
    case rungB
    case rungC
}

public enum FocusStepResult: Sendable, Equatable {
    case performed
    case staleCandidate
    case refused
    case notTrusted
}

public enum KeyWindowCheck: Sendable, Equatable {
    case matches
    case differs
    case unknown
}

public enum FocusFailure: String, Sendable, Equatable, Codable {
    case notTrusted
    case windowNotFound
    case staleCandidate
    case unverified
    case timedOut
}

public enum FocusOutcome: Sendable, Equatable {
    case switched(FocusStrategy)
    case alreadyFocused
    case failed(FocusFailure)
}

public enum VetoDisposition: Sendable, Equatable {
    case clear
    case dropout
    case hold
}

public enum SafetyVeto: String, CaseIterable, Sendable, Equatable, Codable {
    case paused
    case sessionInactive
    case secureInput
    case uncalibrated
    case noGaze
    case staleGaze
    case lowConfidence
    case multipleFaces
    case lookingDown
    case sourceNotAllowed
    case pointerActive
    case failureBackoff
    case typing
    case cooldown

    public var disposition: VetoDisposition {
        switch self {
        case .paused, .sessionInactive, .secureInput, .uncalibrated,
             .sourceNotAllowed, .pointerActive, .failureBackoff, .typing:
            return .clear
        case .noGaze, .staleGaze, .lowConfidence, .multipleFaces, .lookingDown:
            return .dropout
        case .cooldown:
            return .hold
        }
    }
}

public enum SafetyVerdict: Sendable, Equatable {
    case allow
    case deny(SafetyVeto)
}

public struct SafetyContext: Sendable, Equatable {
    public var now: TimeInterval
    public var isPaused: Bool
    public var isSessionActive: Bool
    public var input: InputActivity
    public var gaze: GazeObservation
    public var faceCount: Int
    public var headPitch: Double?
    public var pitchDownLimit: Double?
    public var frontmostBundleID: String?
    public var lastSwitchAt: TimeInterval?
    public var lastFailureAt: TimeInterval?
    public var config: Config
    public var securityPromptVisible: Bool

    public init(
        now: TimeInterval,
        isPaused: Bool,
        isSessionActive: Bool,
        input: InputActivity,
        gaze: GazeObservation,
        faceCount: Int,
        headPitch: Double?,
        pitchDownLimit: Double?,
        frontmostBundleID: String?,
        lastSwitchAt: TimeInterval?,
        lastFailureAt: TimeInterval?,
        config: Config,
        securityPromptVisible: Bool = false
    ) {
        self.now = now
        self.isPaused = isPaused
        self.isSessionActive = isSessionActive
        self.input = input
        self.gaze = gaze
        self.faceCount = faceCount
        self.headPitch = headPitch
        self.pitchDownLimit = pitchDownLimit
        self.frontmostBundleID = frontmostBundleID
        self.lastSwitchAt = lastSwitchAt
        self.lastFailureAt = lastFailureAt
        self.config = config
        self.securityPromptVisible = securityPromptVisible
    }
}

public struct EngineInput: Sendable, Equatable {
    public var now: TimeInterval
    public var gaze: GazeObservation
    public var faceCount: Int
    public var headPitch: Double?
    public var pitchDownLimit: Double?
    public var snapshot: WindowSnapshot
    public var topology: DisplayTopology
    public var input: InputActivity
    public var isPaused: Bool
    public var isSessionActive: Bool

    public init(
        now: TimeInterval,
        gaze: GazeObservation,
        faceCount: Int,
        headPitch: Double?,
        pitchDownLimit: Double?,
        snapshot: WindowSnapshot,
        topology: DisplayTopology,
        input: InputActivity,
        isPaused: Bool,
        isSessionActive: Bool
    ) {
        self.now = now
        self.gaze = gaze
        self.faceCount = faceCount
        self.headPitch = headPitch
        self.pitchDownLimit = pitchDownLimit
        self.snapshot = snapshot
        self.topology = topology
        self.input = input
        self.isPaused = isPaused
        self.isSessionActive = isSessionActive
    }
}

public enum EngineAction: Sendable, Equatable {
    case none
    case focus(WindowDescriptor)
}

public struct EngineOutput: Sendable, Equatable {
    public var action: EngineAction
    public var veto: SafetyVeto?
    public var candidateWindowID: UInt32?
    public var dwellProgress: Double

    public init(
        action: EngineAction,
        veto: SafetyVeto?,
        candidateWindowID: UInt32?,
        dwellProgress: Double
    ) {
        self.action = action
        self.veto = veto
        self.candidateWindowID = candidateWindowID
        self.dwellProgress = dwellProgress
    }
}

public struct PipelineEnvironment: Sendable, Equatable {
    public var snapshot: WindowSnapshot
    public var topology: DisplayTopology
    public var input: InputActivity
    public var isPaused: Bool
    public var isSessionActive: Bool
    public var now: TimeInterval

    public init(
        snapshot: WindowSnapshot,
        topology: DisplayTopology,
        input: InputActivity,
        isPaused: Bool,
        isSessionActive: Bool,
        now: TimeInterval
    ) {
        self.snapshot = snapshot
        self.topology = topology
        self.input = input
        self.isPaused = isPaused
        self.isSessionActive = isSessionActive
        self.now = now
    }
}

public enum CoordinatorStateKind: String, Sendable, Equatable {
    case running
    case paused
    case needsPermission
    case needsCalibration
    case error
}

public struct CoordinatorStatus: Sendable, Equatable {
    public var state: CoordinatorStateKind
    public var lastVeto: SafetyVeto?
    public var failureCount: Int
    public var candidateWindowID: UInt32?
    public var dwellProgress: Double
    public var detail: String?

    public init(
        state: CoordinatorStateKind,
        lastVeto: SafetyVeto? = nil,
        failureCount: Int = 0,
        candidateWindowID: UInt32? = nil,
        dwellProgress: Double = 0,
        detail: String? = nil
    ) {
        self.state = state
        self.lastVeto = lastVeto
        self.failureCount = failureCount
        self.candidateWindowID = candidateWindowID
        self.dwellProgress = dwellProgress
        self.detail = detail
    }
}

public enum CoordinatorEvent: Sendable, Equatable {
    case status(CoordinatorStatus)
    case switched(WindowDescriptor, FocusStrategy)
    case failed(WindowDescriptor, FocusFailure)
}
