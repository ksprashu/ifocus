import Foundation

public struct FocusPipeline: Sendable {
    public private(set) var config: Config
    public private(set) var profile: CalibrationProfile?

    private var featurePipeline = GazeFeaturePipeline()
    private var engine: FocusDecisionEngine
    private var previousDisplayUUID: String?
    private var lastObservation: GazeObservation = .uncalibrated
    private var lastFaceCount: Int = 0
    private var lastHeadPitch: Double?

    public init(config: Config, profile: CalibrationProfile?, policy: any SafetyGuardPolicy = DefaultSafetyGuardPolicy()) {
        self.config = config
        if let profile, profile.validate() == nil {
            self.profile = profile
        } else {
            self.profile = nil
        }
        self.engine = FocusDecisionEngine(config: config, policy: policy)
    }

    public var failureCount: Int {
        engine.failureCount
    }

    public var lastSwitchAt: TimeInterval? {
        engine.lastSwitchAt
    }

    public var lastGazeObservation: GazeObservation {
        lastObservation
    }

    public mutating func updateConfig(_ newConfig: Config) {
        let clamped = newConfig.clamped()
        self.config = clamped
        self.engine.config = clamped
    }

    public mutating func updateProfile(_ newProfile: CalibrationProfile?) {
        if let newProfile, newProfile.validate() == nil {
            self.profile = newProfile
        } else {
            self.profile = nil
        }
    }

    public mutating func ingest(_ event: GazeEvent, env: PipelineEnvironment) -> EngineOutput {
        switch event {
        case .noFace:
            lastFaceCount = 0
            lastHeadPitch = nil
            if env.topology.displays.isEmpty {
                lastObservation = .offScreen
            } else if !hasCalibratedDisplay(in: env.topology) {
                lastObservation = .uncalibrated
            } else {
                lastObservation = .noFace
            }

        case .interrupted:
            featurePipeline.reset()
            lastFaceCount = 0
            lastHeadPitch = nil
            if env.topology.displays.isEmpty {
                lastObservation = .offScreen
            } else if !hasCalibratedDisplay(in: env.topology) {
                lastObservation = .uncalibrated
            } else {
                lastObservation = .noFace
            }

        case .features(let rawFeatures):
            let conditioned = featurePipeline.process(rawFeatures, config: config)
            let observation = CalibrationMapper.map(
                conditioned,
                topology: env.topology,
                profile: profile,
                previousDisplayUUID: previousDisplayUUID,
                config: config
            )
            if case .point(let pt) = observation {
                previousDisplayUUID = pt.displayUUID
            }
            lastObservation = observation
            lastFaceCount = conditioned.faceCount
            lastHeadPitch = conditioned.pitch
        }

        let engineInput = EngineInput(
            now: env.now,
            gaze: lastObservation,
            faceCount: lastFaceCount,
            headPitch: lastHeadPitch,
            pitchDownLimit: profile?.pitchDownLimit,
            snapshot: env.snapshot,
            topology: env.topology,
            input: env.input,
            isPaused: env.isPaused,
            isSessionActive: env.isSessionActive
        )
        return engine.step(engineInput)
    }

    public func confirm(_ target: WindowDescriptor, env: PipelineEnvironment) -> Bool {
        let engineInput = EngineInput(
            now: env.now,
            gaze: lastObservation,
            faceCount: lastFaceCount,
            headPitch: lastHeadPitch,
            pitchDownLimit: profile?.pitchDownLimit,
            snapshot: env.snapshot,
            topology: env.topology,
            input: env.input,
            isPaused: env.isPaused,
            isSessionActive: env.isSessionActive
        )
        return engine.confirm(target, with: engineInput)
    }

    public mutating func recordOutcome(_ outcome: FocusOutcome, at now: TimeInterval) {
        engine.recordOutcome(outcome, at: now)
    }

    private func hasCalibratedDisplay(in topology: DisplayTopology) -> Bool {
        guard let profile else { return false }
        return topology.displays.contains { profile.models[$0.uuid] != nil }
    }
}
