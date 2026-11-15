import AppKit
import CoreGraphics
import Foundation
import iFocusCore

public final class CGDisplayTopologyService: DisplayTopologyService, Sendable {
    public init() {}

    public func current() async -> DisplayTopology {
        Self.readCurrentSync()
    }

    public static func readCurrentSync() -> DisplayTopology {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return .empty
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        var actualCount: UInt32 = 0
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &actualCount) == .success, actualCount > 0 else {
            return .empty
        }

        let mainID = CGMainDisplayID()
        let primaryHeight = CGDisplayBounds(mainID).height
        var descriptors: [DisplayDescriptor] = []
        descriptors.reserveCapacity(Int(actualCount))

        for id in displayIDs.prefix(Int(actualCount)) {
            let bounds = CGDisplayBounds(id)
            let sizeMM = CGDisplayScreenSize(id)
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            let isMain = CGDisplayIsMain(id) != 0

            let uuid: String
            if let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
               let cfStr = CFUUIDCreateString(nil, cfUUID) as String? {
                uuid = cfStr
            } else {
                uuid = "display-\(id)"
            }

            descriptors.append(DisplayDescriptor(
                id: id,
                uuid: uuid,
                bounds: bounds,
                physicalSizeMM: sizeMM,
                isBuiltin: isBuiltin,
                isMain: isMain
            ))
        }

        return DisplayTopology(displays: descriptors, primaryHeight: primaryHeight)
    }

    public func updates() -> AsyncStream<DisplayTopology> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: DisplayTopology.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        let task = Task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                continuation.yield(Self.readCurrentSync())
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }
}
