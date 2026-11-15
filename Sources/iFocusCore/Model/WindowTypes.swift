import CoreGraphics
import Foundation

public struct WindowDescriptor: Sendable, Equatable, Codable {
    public var windowID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var bounds: CGRect
    public var zIndex: Int
    public var layer: Int

    public init(
        windowID: UInt32,
        pid: Int32,
        bundleID: String?,
        bounds: CGRect,
        zIndex: Int,
        layer: Int = 0
    ) {
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.bounds = bounds
        self.zIndex = zIndex
        self.layer = layer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.windowID = try container.decode(UInt32.self, forKey: .windowID)
        self.pid = try container.decode(Int32.self, forKey: .pid)
        self.bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        self.bounds = try container.decode(CGRect.self, forKey: .bounds)
        self.zIndex = try container.decode(Int.self, forKey: .zIndex)
        self.layer = try container.decodeIfPresent(Int.self, forKey: .layer) ?? 0
    }
}

public struct WindowSnapshot: Sendable, Equatable, Codable {
    public var windows: [WindowDescriptor]
    public var frontmostPID: Int32?
    public var frontmostBundleID: String?
    public var focusedWindowID: UInt32?
    public var takenAt: TimeInterval

    public init(
        windows: [WindowDescriptor],
        frontmostPID: Int32?,
        frontmostBundleID: String?,
        focusedWindowID: UInt32?,
        takenAt: TimeInterval
    ) {
        self.windows = windows
        self.frontmostPID = frontmostPID
        self.frontmostBundleID = frontmostBundleID
        self.focusedWindowID = focusedWindowID
        self.takenAt = takenAt
    }

    public static func empty(at takenAt: TimeInterval = 0) -> WindowSnapshot {
        WindowSnapshot(
            windows: [],
            frontmostPID: nil,
            frontmostBundleID: nil,
            focusedWindowID: nil,
            takenAt: takenAt
        )
    }

    public func window(id: UInt32) -> WindowDescriptor? {
        windows.first { $0.windowID == id }
    }

    public static func resolveFocusedWindowID(windows: [WindowDescriptor], frontmostPID: Int32?) -> UInt32? {
        guard let frontmostPID else { return nil }
        let ordered = windows.sorted { $0.zIndex < $1.zIndex }
        let layerZero = ordered.filter { $0.pid == frontmostPID && $0.layer == 0 }
        if let primary = layerZero.first(where: { $0.bounds.width >= 120 && $0.bounds.height >= 80 }) {
            return primary.windowID
        }
        return layerZero.first?.windowID
    }
}

public enum HitResult: Sendable, Equatable {
    case window(WindowDescriptor)
    case blocked
    case none
}

public struct AXWindowCandidate: Sendable, Equatable {
    public var index: Int
    public var windowID: UInt32?
    public var frame: CGRect?
    public var isMinimized: Bool
    public var subrole: String?

    public init(
        index: Int,
        windowID: UInt32? = nil,
        frame: CGRect? = nil,
        isMinimized: Bool = false,
        subrole: String? = nil
    ) {
        self.index = index
        self.windowID = windowID
        self.frame = frame
        self.isMinimized = isMinimized
        self.subrole = subrole
    }
}

public enum AXMatch: Sendable, Equatable {
    case exact(Int)
    case geometric(Int)
    case ambiguous(index: Int, count: Int)
    case approximate(Int)
    case notFound
}
