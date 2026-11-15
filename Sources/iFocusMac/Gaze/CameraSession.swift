import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import iFocusCore

public enum CameraError: Error, Sendable, CustomStringConvertible {
    case usageDescriptionMissing
    case permissionDenied
    case cameraUnavailable(String)
    case configurationFailed(String)

    public var description: String {
        switch self {
        case .usageDescriptionMissing:
            return "NSCameraUsageDescription is missing from Info.plist"
        case .permissionDenied:
            return "Camera access permission is denied"
        case .cameraUnavailable(let reason):
            return "Camera unavailable: \(reason)"
        case .configurationFailed(let reason):
            return "Camera configuration failed: \(reason)"
        }
    }
}

public struct CameraDeviceDescriptor: Sendable, Equatable {
    public var uniqueID: String
    public var localizedName: String
    public var isDefault: Bool

    public init(uniqueID: String, localizedName: String, isDefault: Bool) {
        self.uniqueID = uniqueID
        self.localizedName = localizedName
        self.isDefault = isDefault
    }
}

// Thread-safety invariant: `session`, `isRunning`, `observerTokens`, `activeContinuation`, and `processor`
// state are strictly confined to the serial `queue` (`dev.ifocus.camera.session`). Neither `AVCaptureSession`
// nor `AVCaptureDevice` escapes this queue or is captured in a `@Sendable` closure.
public final class CameraSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.ifocus.camera.session", qos: .userInteractive)
    private let processor: FrameProcessor
    private var session: AVCaptureSession?
    private var isRunning = false
    private var activeContinuation: AsyncStream<GazeEvent>.Continuation?
    private var observerTokens: [NSObjectProtocol] = []

    public init(clock: any MonotonicClock, targetFPS: Int) {
        self.processor = FrameProcessor(clock: clock, targetFPS: targetFPS)
    }

    public static func availableDevices() -> [CameraDeviceDescriptor] {
        let defaultID = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)?.uniqueID
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { dev in
            CameraDeviceDescriptor(
                uniqueID: dev.uniqueID,
                localizedName: dev.localizedName,
                isDefault: dev.uniqueID == defaultID
            )
        }
    }

    public static func resolveDevice(uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID, !uniqueID.isEmpty {
            return AVCaptureDevice(uniqueID: uniqueID)
        }
        if let builtIn = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) {
            return builtIn
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first
    }

    public func start(
        cameraUniqueID: String?,
        targetFPS: Int,
        continuation: AsyncStream<GazeEvent>.Continuation
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: CameraError.configurationFailed("CameraSession deallocated"))
                    return
                }
                do {
                    try self.startOnQueue(
                        cameraUniqueID: cameraUniqueID,
                        targetFPS: targetFPS,
                        continuation: continuation
                    )
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.stopOnQueue()
                cont.resume()
            }
        }
    }

    private func startOnQueue(
        cameraUniqueID: String?,
        targetFPS: Int,
        continuation: AsyncStream<GazeEvent>.Continuation
    ) throws {
        if isRunning {
            activeContinuation?.finish()
            processor.attach(continuation: continuation, targetFPS: targetFPS)
            activeContinuation = continuation
            return
        }

        guard let device = Self.resolveDevice(uniqueID: cameraUniqueID) else {
            throw CameraError.cameraUnavailable(cameraUniqueID ?? "default camera")
        }

        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        if newSession.canSetSessionPreset(.hd1280x720) {
            newSession.sessionPreset = .hd1280x720
        } else if newSession.canSetSessionPreset(.vga640x480) {
            newSession.sessionPreset = .vga640x480
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            newSession.commitConfiguration()
            throw CameraError.configurationFailed("Cannot open camera input: \(error)")
        }

        guard newSession.canAddInput(input) else {
            newSession.commitConfiguration()
            throw CameraError.configurationFailed("Session refused camera input")
        }
        newSession.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        let fullRangeYUV = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        if output.availableVideoPixelFormatTypes.contains(fullRangeYUV) {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: fullRangeYUV,
            ]
        }

        guard newSession.canAddOutput(output) else {
            newSession.commitConfiguration()
            throw CameraError.configurationFailed("Session refused video output")
        }
        newSession.addOutput(output)

        let clampedFPS = Double(min(max(targetFPS, 5), 30))
        processor.attach(continuation: continuation, targetFPS: Int(clampedFPS))
        output.setSampleBufferDelegate(processor, queue: queue)
        newSession.commitConfiguration()

        // TRG-23: query activeFormat after commitConfiguration(), and unlock after startRunning().
        var lockedDevice = false
        let supportsRequestedFPS = device.activeFormat.videoSupportedFrameRateRanges.contains { range in
            clampedFPS >= (range.minFrameRate - 1e-6) && clampedFPS <= (range.maxFrameRate + 1e-6)
        }
        if supportsRequestedFPS {
            do {
                try device.lockForConfiguration()
                lockedDevice = true
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clampedFPS))
            } catch {
                lockedDevice = false
            }
        }

        newSession.startRunning()
        if lockedDevice {
            device.unlockForConfiguration()
        }

        session = newSession
        isRunning = true
        activeContinuation = continuation
        registerObserversOnQueue(session: newSession, device: device)
    }

    private func registerObserversOnQueue(session: AVCaptureSession, device: AVCaptureDevice) {
        removeObserversOnQueue()
        let center = NotificationCenter.default

        let runtimeErrToken = center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            let errText = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "runtime error"
            let reason = "Camera session error: \(errText)"
            guard let self else { return }
            self.queue.async {
                self.handleInterruptionOnQueue(reason: reason)
            }
        }

        let interruptedToken = center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.handleInterruptionOnQueue(reason: "Camera session interrupted")
            }
        }

        let disconnectedToken = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.handleInterruptionOnQueue(reason: "Camera disconnected")
            }
        }

        observerTokens = [runtimeErrToken, interruptedToken, disconnectedToken]
    }

    private func removeObserversOnQueue() {
        let center = NotificationCenter.default
        for token in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    private func handleInterruptionOnQueue(reason: String) {
        guard isRunning else { return }
        activeContinuation?.yield(.interrupted(reason))
        stopOnQueue()
    }

    private func stopOnQueue() {
        removeObserversOnQueue()
        processor.detach()
        if let session, session.isRunning {
            session.stopRunning()
        }
        session = nil
        isRunning = false
        activeContinuation?.finish()
        activeContinuation = nil
    }
}
