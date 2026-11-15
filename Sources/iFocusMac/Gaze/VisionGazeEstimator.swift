import AVFoundation
import Foundation
import iFocusCore

public actor VisionGazeEstimator: GazeEstimator {
    private let clock: any MonotonicClock
    private var cameraUniqueID: String?
    private var targetFPS: Int

    private var cameraSession: CameraSession?
    private var streamContinuation: AsyncStream<GazeEvent>.Continuation?
    private var isStarted = false

    public init(
        clock: any MonotonicClock = SystemClock(),
        cameraUniqueID: String? = nil,
        targetFPS: Int = 20
    ) {
        self.clock = clock
        self.cameraUniqueID = cameraUniqueID
        self.targetFPS = min(max(targetFPS, 5), 30)
    }

    public func updateSettings(cameraUniqueID: String?, targetFPS: Int) {
        self.cameraUniqueID = cameraUniqueID
        self.targetFPS = min(max(targetFPS, 5), 30)
    }

    public func activeCameraUniqueID() -> String? {
        if let cameraUniqueID, !cameraUniqueID.isEmpty {
            return cameraUniqueID
        }
        return CameraSession.resolveDevice(uniqueID: nil)?.uniqueID
    }

    public func start() async throws -> AsyncStream<GazeEvent> {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            throw CameraError.usageDescriptionMissing
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            throw CameraError.permissionDenied
        }

        if isStarted, let existing = cameraSession {
            streamContinuation?.finish()
            let (stream, continuation) = AsyncStream.makeStream(
                of: GazeEvent.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            streamContinuation = continuation
            try await existing.start(
                cameraUniqueID: cameraUniqueID,
                targetFPS: targetFPS,
                continuation: continuation
            )
            return stream
        }

        streamContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(
            of: GazeEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let session = CameraSession(clock: clock, targetFPS: targetFPS)
        try await session.start(
            cameraUniqueID: cameraUniqueID,
            targetFPS: targetFPS,
            continuation: continuation
        )
        cameraSession = session
        streamContinuation = continuation
        isStarted = true
        return stream
    }

    public func stop() async {
        isStarted = false
        streamContinuation?.finish()
        streamContinuation = nil
        if let session = cameraSession {
            await session.stop()
        }
        cameraSession = nil
    }
}
