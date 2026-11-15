import CoreGraphics
import Foundation

public struct DisplayDescriptor: Sendable, Equatable, Codable {
    public var id: UInt32
    public var uuid: String
    public var bounds: CGRect
    public var physicalSizeMM: CGSize
    public var isBuiltin: Bool
    public var isMain: Bool

    public init(
        id: UInt32,
        uuid: String,
        bounds: CGRect,
        physicalSizeMM: CGSize,
        isBuiltin: Bool,
        isMain: Bool
    ) {
        self.id = id
        self.uuid = uuid
        self.bounds = bounds
        self.physicalSizeMM = physicalSizeMM
        self.isBuiltin = isBuiltin
        self.isMain = isMain
    }
}

public struct DisplayTopology: Sendable, Equatable, Codable {
    public var displays: [DisplayDescriptor]
    public var primaryHeight: CGFloat

    public init(displays: [DisplayDescriptor], primaryHeight: CGFloat? = nil) {
        self.displays = displays
        if let primaryHeight {
            self.primaryHeight = primaryHeight
        } else {
            self.primaryHeight = displays.first(where: \.isMain)?.bounds.height
                ?? displays.first?.bounds.height
                ?? 0
        }
    }

    public static let empty = DisplayTopology(displays: [], primaryHeight: 0)

    public func display(uuid: String) -> DisplayDescriptor? {
        displays.first { $0.uuid == uuid }
    }

    public func display(containing p: CGPoint) -> DisplayDescriptor? {
        displays.first { $0.bounds.contains(p) }
    }

    public func display(bestFor rect: CGRect) -> DisplayDescriptor? {
        var best: DisplayDescriptor?
        var bestArea: CGFloat = 0
        for display in displays {
            let intersection = display.bounds.intersection(rect)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = display
            }
        }
        return best
    }
}
