import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Vision
import iFocusCore

// Thread-safety invariant: all mutable state (`decimator`, `continuation`)
// is confined strictly to the camera serial DispatchQueue provided to `setSampleBufferDelegate(_:queue:)`.
public final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let clock: any MonotonicClock
    private var decimator: FrameDecimator
    private var continuation: AsyncStream<GazeEvent>.Continuation?

    public init(clock: any MonotonicClock, targetFPS: Int) {
        self.clock = clock
        self.decimator = FrameDecimator(targetFPS: targetFPS)
        super.init()
    }

    public func attach(continuation: AsyncStream<GazeEvent>.Continuation, targetFPS: Int) {
        self.continuation = continuation
        self.decimator = FrameDecimator(targetFPS: targetFPS)
    }

    public func detach() {
        self.continuation = nil
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = clock.now()
        guard decimator.shouldProcess(at: now) else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }
        let imageSize = CGSize(width: width, height: height)

        let event = processPixelBuffer(pixelBuffer, imageSize: imageSize, timestamp: now)
        continuation?.yield(event)
    }

    private func processPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        imageSize: CGSize,
        timestamp: TimeInterval
    ) -> GazeEvent {
        let rectReq = VNDetectFaceRectanglesRequest()
        rectReq.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([rectReq])
        } catch {
            return .noFace(timestamp)
        }

        let faces = rectReq.results ?? []
        guard let largest = faces.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }) else {
            return .noFace(timestamp)
        }

        let landmarksReq = VNDetectFaceLandmarksRequest()
        landmarksReq.revision = VNDetectFaceLandmarksRequestRevision3
        landmarksReq.inputFaceObservations = [largest]

        do {
            try handler.perform([landmarksReq])
        } catch {
            return .noFace(timestamp)
        }

        let landmarkObs = landmarksReq.results?.first
        guard let yaw = (largest.yaw ?? landmarkObs?.yaw)?.doubleValue,
              let pitch = (largest.pitch ?? landmarkObs?.pitch)?.doubleValue,
              yaw.isFinite,
              pitch.isFinite else {
            return .noFace(timestamp)
        }

        let roll = (largest.roll ?? landmarkObs?.roll)?.doubleValue ?? 0.0
        let safeRoll = roll.isFinite ? roll : 0.0

        let landmarks = landmarkObs?.landmarks
        let eyeOffset = EyeGeometry.eyeOffset(
            leftContour: landmarks?.leftEye?.pointsInImage(imageSize: imageSize),
            leftPupil: landmarks?.leftPupil?.pointsInImage(imageSize: imageSize),
            rightContour: landmarks?.rightEye?.pointsInImage(imageSize: imageSize),
            rightPupil: landmarks?.rightPupil?.pointsInImage(imageSize: imageSize)
        )

        let faceCenter = CGPoint(x: largest.boundingBox.midX, y: largest.boundingBox.midY)
        let faceScale = Double(largest.boundingBox.height)
        let confidence = Double(largest.confidence)

        return .features(GazeFeatures(
            timestamp: timestamp,
            yaw: yaw,
            pitch: pitch,
            roll: safeRoll,
            eyeX: eyeOffset?.x,
            eyeY: eyeOffset?.y,
            faceCenter: faceCenter,
            faceScale: faceScale,
            confidence: confidence,
            faceCount: faces.count
        ))
    }
}
