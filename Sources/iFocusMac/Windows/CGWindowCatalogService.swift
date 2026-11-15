import AppKit
import CoreGraphics
import Foundation
import iFocusCore

public actor CGWindowCatalogService: WindowCatalogService {
    public struct WindowInspection: Sendable {
        public var descriptor: WindowDescriptor
        public var role: WindowRole
        public var ownerName: String?
        public var usedOwnerNameFallback: Bool
    }

    private let ownPID: Int32 = ProcessInfo.processInfo.processIdentifier

    public init() {}

    public func snapshot() async -> WindowSnapshot {
        await detailedSnapshot().snapshot
    }

    public func detailedSnapshot() async -> (snapshot: WindowSnapshot, inspections: [WindowInspection]) {
        let now = ProcessInfo.processInfo.systemUptime
        let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] ?? []

        let wsFrontmost = await MainActor.run { () -> (pid: Int32?, bundleID: String?) in
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.processIdentifier, app?.bundleIdentifier)
        }

        let displayBounds = Self.activeDisplayBounds()
        // TRG-12: local per-snapshot PID cache avoids PID-wraparound stale bundle IDs.
        var pidBundleCache: [Int32: String?] = [:]

        var windows: [WindowDescriptor] = []
        var inspections: [WindowInspection] = []
        windows.reserveCapacity(rawList.count)

        for entry in rawList {
            guard let layer = (entry[kCGWindowLayer] as? NSNumber)?.intValue else { continue }
            let alpha = (entry[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1.0
            guard let pidNum = (entry[kCGWindowOwnerPID] as? NSNumber)?.int32Value else { continue }
            guard let winNum = (entry[kCGWindowNumber] as? NSNumber)?.uint32Value else { continue }
            guard let boundsDict = entry[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }

            let rawBundleID: String?
            if let cached = pidBundleCache[pidNum] {
                rawBundleID = cached
            } else {
                let resolved = NSRunningApplication(processIdentifier: pidNum)?.bundleIdentifier
                pidBundleCache[pidNum] = resolved
                rawBundleID = resolved
            }

            let ownerName = entry[kCGWindowOwnerName] as? String
            let canonicalBundle = WindowClassifier.canonicalBundleID(
                bundleID: rawBundleID,
                ownerName: ownerName
            )
            let usedFallback = (rawBundleID == nil || rawBundleID?.isEmpty == true) && canonicalBundle != nil

            let role = WindowClassifier.classify(
                layer: layer,
                alpha: alpha,
                pid: pidNum,
                ownPID: ownPID,
                bundleID: canonicalBundle,
                bounds: bounds,
                displayBounds: displayBounds
            )

            guard role != .ignored else { continue }

            let descriptor = WindowDescriptor(
                windowID: winNum,
                pid: pidNum,
                bundleID: canonicalBundle,
                bounds: bounds,
                zIndex: windows.count,
                layer: layer
            )
            windows.append(descriptor)
            inspections.append(WindowInspection(
                descriptor: descriptor,
                role: role,
                ownerName: ownerName,
                usedOwnerNameFallback: usedFallback
            ))
        }

        let frontmostPID = wsFrontmost.pid ?? windows.first(where: { $0.layer == 0 })?.pid ?? windows.first?.pid
        let frontmostBundleID: String?
        if let fpid = frontmostPID {
            let resolvedFront = pidBundleCache[fpid] ?? NSRunningApplication(processIdentifier: fpid)?.bundleIdentifier
            frontmostBundleID = wsFrontmost.bundleID
                ?? resolvedFront
                ?? windows.first(where: { $0.pid == fpid })?.bundleID
        } else {
            frontmostBundleID = nil
        }

        let focusedWindowID = WindowSnapshot.resolveFocusedWindowID(
            windows: windows,
            frontmostPID: frontmostPID
        )

        let snap = WindowSnapshot(
            windows: windows,
            frontmostPID: frontmostPID,
            frontmostBundleID: frontmostBundleID,
            focusedWindowID: focusedWindowID,
            takenAt: now
        )
        return (snap, inspections)
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        guard CGGetActiveDisplayList(count, &ids, &actual) == .success, actual > 0 else {
            return []
        }
        return ids.prefix(Int(actual)).map { CGDisplayBounds($0) }
    }
}
