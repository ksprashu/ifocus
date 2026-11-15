import CoreGraphics
import Foundation

public struct Vec3: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }
}

public struct SimDisplay: Sendable, Equatable {
    public var descriptor: DisplayDescriptor
    public var centerMM: Vec3
    public var yawDegrees: Double
    public var tiltBackDegrees: Double

    public init(
        descriptor: DisplayDescriptor,
        centerMM: Vec3,
        yawDegrees: Double = 0,
        tiltBackDegrees: Double = 0
    ) {
        self.descriptor = descriptor
        self.centerMM = centerMM
        self.yawDegrees = yawDegrees
        self.tiltBackDegrees = tiltBackDegrees
    }

    public func worldPoint(u: Double, v: Double) -> Vec3 {
        let localX = (u - 0.5) * Double(descriptor.physicalSizeMM.width)
        let localY = (0.5 - v) * Double(descriptor.physicalSizeMM.height)

        let tiltRad = tiltBackDegrees * Double.pi / 180.0
        let tiltedY = localY * cos(tiltRad)
        let tiltedZ = localY * sin(tiltRad)

        let yawRad = yawDegrees * Double.pi / 180.0
        let rotatedX = localX * cos(yawRad) + tiltedZ * sin(yawRad)
        let rotatedZ = -localX * sin(yawRad) + tiltedZ * cos(yawRad)

        return Vec3(
            x: centerMM.x + rotatedX,
            y: centerMM.y + tiltedY,
            z: centerMM.z + rotatedZ
        )
    }

    public func worldPoint(forGlobalPoint p: CGPoint) -> Vec3 {
        let u = Double((p.x - descriptor.bounds.minX) / max(descriptor.bounds.width, 1))
        let v = Double((p.y - descriptor.bounds.minY) / max(descriptor.bounds.height, 1))
        return worldPoint(u: u, v: v)
    }
}

public struct SimRig: Sendable, Equatable {
    public var name: String
    public var displays: [SimDisplay]
    public var eyePositionMM: Vec3
    public var windows: [WindowDescriptor]

    public init(
        name: String,
        displays: [SimDisplay],
        eyePositionMM: Vec3 = Vec3(x: 0, y: 0, z: 0),
        windows: [WindowDescriptor]
    ) {
        self.name = name
        self.displays = displays
        self.eyePositionMM = eyePositionMM
        self.windows = windows
    }

    public var topology: DisplayTopology {
        DisplayTopology(displays: displays.map(\.descriptor))
    }

    public func display(uuid: String) -> SimDisplay? {
        displays.first { $0.descriptor.uuid == uuid }
    }

    public func display(forWindowID id: UInt32) -> SimDisplay? {
        guard let window = windows.first(where: { $0.windowID == id }),
              let descriptor = topology.display(bestFor: window.bounds) else {
            return nil
        }
        return display(uuid: descriptor.uuid)
    }

    public func worldPoint(forWindowID id: UInt32) -> Vec3? {
        guard let window = windows.first(where: { $0.windowID == id }) else {
            return nil
        }
        let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        return worldPoint(forGlobalPoint: center)
    }

    public func worldPoint(forGlobalPoint point: CGPoint) -> Vec3? {
        if let desc = topology.display(containing: point),
           let simDisplay = display(uuid: desc.uuid) {
            return simDisplay.worldPoint(forGlobalPoint: point)
        }
        // If point lies slightly outside all display bounds, project onto the nearest display plane.
        let nearest = displays.min { a, b in
            WindowHitTester.distance(from: point, to: a.descriptor.bounds)
                < WindowHitTester.distance(from: point, to: b.descriptor.bounds)
        }
        return nearest?.worldPoint(forGlobalPoint: point)
    }
}
