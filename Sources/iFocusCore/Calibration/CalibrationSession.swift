import Foundation

public enum CalibrationPlan {
    public static func standard(for topology: DisplayTopology, includeEyesOnlyPass: Bool = true) -> [CalibrationTarget] {
        var targets: [CalibrationTarget] = []
        targets.reserveCapacity(topology.displays.count * (includeEyesOnlyPass ? 9 : 5))

        let naturalPoints: [(Double, Double)] = [
            (0.1, 0.1),
            (0.9, 0.1),
            (0.9, 0.9),
            (0.1, 0.9),
            (0.5, 0.5),
        ]
        let eyesOnlyPoints: [(Double, Double)] = [
            (0.1, 0.1),
            (0.9, 0.1),
            (0.9, 0.9),
            (0.1, 0.9),
        ]

        for display in topology.displays {
            for (u, v) in naturalPoints {
                targets.append(CalibrationTarget(displayUUID: display.uuid, u: u, v: v, pass: .natural))
            }
            if includeEyesOnlyPass {
                for (u, v) in eyesOnlyPoints {
                    targets.append(CalibrationTarget(displayUUID: display.uuid, u: u, v: v, pass: .eyesOnly))
                }
            }
        }
        return targets
    }
}

public enum CalibrationProgress: Sendable, Equatable {
    case settling(CalibrationTarget, progress: Double)
    case capturing(CalibrationTarget, sampleCount: Int, progress: Double)
    case repeating(CalibrationTarget, attempt: Int)
    case advanced(CalibrationTarget)
    case finished
    case failed(CalibrationError)
}

public struct CalibrationSession: Sendable {
    public let plan: [CalibrationTarget]
    public let settle: TimeInterval
    public let capture: TimeInterval
    public let minSamples: Int
    public let minConfidence: Double
    public let maxRepeats: Int = 3

    private var currentIndex: Int = 0
    private var targetStartTime: TimeInterval?
    private var repeatCount: Int = 0
    private var currentSamples: [GazeFeatures] = []
    private var collectedSamples: [CalibrationSample] = []
    private var featurePipeline = GazeFeaturePipeline()
    private var failedError: CalibrationError?

    public init(
        plan: [CalibrationTarget],
        settle: TimeInterval = 0.6,
        capture: TimeInterval = 0.8,
        minSamples: Int = 8,
        minConfidence: Double = 0.50
    ) {
        self.plan = plan
        self.settle = max(settle, 0)
        self.capture = max(capture, 0.05)
        self.minSamples = max(minSamples, 1)
        self.minConfidence = minConfidence
        if plan.isEmpty {
            self.failedError = .emptyTopology
        }
    }

    public var currentTarget: CalibrationTarget? {
        guard currentIndex < plan.count else { return nil }
        return plan[currentIndex]
    }

    public var isFinished: Bool {
        failedError == nil && currentIndex >= plan.count
    }

    public var capturedSampleCount: Int {
        collectedSamples.count + currentSamples.count
    }

    public mutating func ingest(_ f: GazeFeatures) -> CalibrationProgress {
        if let failedError {
            return .failed(failedError)
        }
        guard currentIndex < plan.count else {
            return .finished
        }
        let target = plan[currentIndex]
        guard f.timestamp.isFinite else {
            return .settling(target, progress: 0)
        }

        if targetStartTime == nil {
            targetStartTime = f.timestamp
        }

        let start = targetStartTime ?? f.timestamp
        let elapsed = f.timestamp - start
        if elapsed < 0 {
            return .settling(target, progress: 0)
        }

        let isValid = f.faceCount == 1
            && f.confidence.isFinite
            && f.confidence >= minConfidence
            && f.yaw.isFinite
            && f.pitch.isFinite
            && f.roll.isFinite

        var conditionedFeatures: GazeFeatures?
        if isValid {
            var filterConfig = Config()
            filterConfig.minConfidence = minConfidence
            let conditioned = featurePipeline.process(f, config: filterConfig)
            conditionedFeatures = GazeFeatures(
                timestamp: f.timestamp,
                yaw: conditioned.yaw,
                pitch: conditioned.pitch,
                roll: f.roll,
                eyeX: conditioned.eye?.x,
                eyeY: conditioned.eye?.y,
                faceCenter: f.faceCenter,
                faceScale: f.faceScale,
                confidence: conditioned.confidence,
                faceCount: conditioned.faceCount
            )
        }

        let eps = 1e-9
        if elapsed + eps < settle {
            let p = settle > 0 ? min(max(elapsed / settle, 0), 1) : 1
            return .settling(target, progress: p)
        }

        if elapsed + eps < settle + capture {
            if let validSample = conditionedFeatures {
                currentSamples.append(validSample)
            }
            let p = min(max((elapsed - settle) / capture, 0), 1)
            return .capturing(target, sampleCount: currentSamples.count, progress: p)
        }

        // Capture window complete
        if currentSamples.count >= minSamples {
            for sample in currentSamples {
                collectedSamples.append(CalibrationSample(target: target, features: sample))
            }
            currentSamples.removeAll()
            repeatCount = 0
            currentIndex += 1
            if currentIndex >= plan.count {
                return .finished
            }
            targetStartTime = f.timestamp
            return .advanced(plan[currentIndex])
        } else {
            currentSamples.removeAll()
            repeatCount += 1
            if repeatCount > maxRepeats {
                failedError = .insufficientSamples
                return .failed(.insufficientSamples)
            }
            targetStartTime = f.timestamp
            return .repeating(target, attempt: repeatCount)
        }
    }

    public func solve(
        cameraUniqueID: String,
        createdAt: TimeInterval,
        config: Config = Config()
    ) -> Result<CalibrationProfile, CalibrationError> {
        if let failedError {
            return .failure(failedError)
        }
        guard currentIndex >= plan.count else {
            return .failure(.insufficientSamples)
        }
        return CalibrationSolver.solve(
            samples: collectedSamples,
            cameraUniqueID: cameraUniqueID,
            createdAt: createdAt,
            config: config
        )
    }
}
