import AVFoundation
import ApplicationServices
import Foundation

public enum CameraPermissionState: String, Sendable {
    case authorized
    case notDetermined = "not determined"
    case denied
    case restricted
}

public enum Permissions {
    public static func cameraStatus() -> CameraPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

    public static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public static func hasCameraUsageDescription() -> Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

    public static func requestCameraAccessIfNeeded() async -> Bool {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        if current == .authorized {
            return true
        }
        if current == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return false
    }

    @MainActor
    public static func promptAccessibilityIfNeeded() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
