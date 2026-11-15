import CoreGraphics
import Foundation

public enum WindowRole: Sendable, Equatable {
    case normal
    case occluder
    case securityPrompt
    case ignored
}

public enum WindowClassifier {
    public static func canonicalBundleID(bundleID: String?, ownerName: String?) -> String? {
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        if let ownerName, !ownerName.isEmpty {
            return Config.promptOwnerNames[ownerName]
        }
        return nil
    }

    public static func classify(
        layer: Int,
        alpha: Double,
        pid: Int32,
        ownPID: Int32,
        bundleID: String?,
        bounds: CGRect,
        displayBounds: [CGRect]
    ) -> WindowRole {
        // Rule 1: Own process, effectively invisible, empty bounds, or below desktop layer.
        if pid == ownPID || alpha <= 0.01 || bounds.isEmpty || bounds.width <= 0 || bounds.height <= 0 || layer < 0 {
            return .ignored
        }

        // Rule 2: Known security prompt owner at any layer >= 0 (>= 40x40 pt).
        if let bundleID,
           Config.securityPromptBundleIDs.contains(bundleID),
           bounds.width >= 40,
           bounds.height >= 40 {
            return .securityPrompt
        }

        // Rule 3: loginwindow shield at high layer (>= 1000).
        if bundleID == "com.apple.loginwindow",
           layer >= 1000,
           bounds.width >= 40,
           bounds.height >= 40 {
            return .securityPrompt
        }

        // Rule 4: Standard layer-0 windows.
        if layer == 0 {
            return .normal
        }

        // Rule 5: Screen-saver / shield / WindowServer high layers above 1000.
        if layer >= 1000 {
            return .ignored
        }

        // Rule 6: Known non-prompt desktop chrome bundles (a nil bundle is NOT ignored here).
        if let bundleID, Config.chromeBundleIDs.contains(bundleID) {
            return .ignored
        }

        // Rule 7: Narrow bars / status items (< 40 pt in either dimension).
        if bounds.width < 40 || bounds.height < 40 {
            return .ignored
        }

        // Rule 8: Full-display transparent/ambient overlays covering >= 80% of any active display.
        if !displayBounds.isEmpty {
            for display in displayBounds where !display.isEmpty {
                let displayArea = display.width * display.height
                guard displayArea > 0 else { continue }
                let intersection = bounds.intersection(display)
                if !intersection.isNull, !intersection.isEmpty {
                    let coveredArea = intersection.width * intersection.height
                    if coveredArea >= 0.80 * displayArea {
                        return .ignored
                    }
                }
            }
        }

        // Rule 9: Any remaining layer > 0 window is treated as an occluder.
        return .occluder
    }
}
