import CoreGraphics
import Foundation

public enum WindowHitTester {
    public static func isEligible(_ window: WindowDescriptor, config: Config) -> Bool {
        guard window.layer == 0 else {
            return false
        }
        guard window.bounds.width >= 120, window.bounds.height >= 80 else {
            return false
        }
        return config.isBundleAllowed(window.bundleID)
    }

    public static func securityPrompt(in snapshot: WindowSnapshot) -> WindowDescriptor? {
        let ordered = snapshot.windows.sorted { $0.zIndex < $1.zIndex }
        for window in ordered {
            guard window.bounds.width >= 40, window.bounds.height >= 40 else { continue }
            if let bundleID = window.bundleID {
                if Config.securityPromptBundleIDs.contains(bundleID) {
                    return window
                }
                if bundleID == "com.apple.loginwindow", window.layer >= 1000 {
                    return window
                }
            }
        }
        return nil
    }

    public static func securityPromptVisible(in snapshot: WindowSnapshot) -> Bool {
        securityPrompt(in: snapshot) != nil
    }

    public static func hitTest(
        _ point: CGPoint,
        in snapshot: WindowSnapshot,
        config: Config
    ) -> HitResult {
        let ordered = snapshot.windows.sorted { $0.zIndex < $1.zIndex }

        for window in ordered {
            if window.bounds.contains(point) {
                return isEligible(window, config: config) ? .window(window) : .blocked
            }
        }

        let snapRadius = config.snapRadiusPoints
        guard snapRadius > 0 else { return .none }

        var bestWindow: WindowDescriptor?
        var bestDistance = Double.infinity

        for window in ordered where isEligible(window, config: config) {
            let d = distance(from: point, to: window.bounds)
            if d <= snapRadius && d < bestDistance {
                bestDistance = d
                bestWindow = window
            }
        }

        guard let candidate = bestWindow else {
            return .none
        }

        // TRG-27: Refuse snap if a non-eligible panel/window lies strictly closer to the gaze point.
        for other in ordered {
            guard other.windowID != candidate.windowID else { continue }
            guard !isEligible(other, config: config) else { continue }
            let isSignificant = other.layer > 0 || (other.bounds.width >= 120 && other.bounds.height >= 80)
            guard isSignificant else { continue }
            if distance(from: point, to: other.bounds) < bestDistance {
                return .none
            }
        }

        let nearest = nearestPoint(on: candidate.bounds, to: point)
        let probe = insetProbe(nearest, inside: candidate.bounds)

        for front in ordered {
            if front.windowID == candidate.windowID { break }
            if front.zIndex >= candidate.zIndex { break }
            if front.bounds.contains(probe) || front.bounds.contains(nearest) {
                return .none
            }
        }

        return .window(candidate)
    }

    public static func distance(from point: CGPoint, to rect: CGRect) -> Double {
        let dx = Double(max(rect.minX - point.x, 0, point.x - rect.maxX))
        let dy = Double(max(rect.minY - point.y, 0, point.y - rect.maxY))
        return hypot(dx, dy)
    }

    public static func nearestPoint(on rect: CGRect, to point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private static func insetProbe(_ point: CGPoint, inside rect: CGRect) -> CGPoint {
        let epsX = min(0.5, rect.width * 0.25)
        let epsY = min(0.5, rect.height * 0.25)
        return CGPoint(
            x: min(max(point.x, rect.minX + epsX), rect.maxX - epsX),
            y: min(max(point.y, rect.minY + epsY), rect.maxY - epsY)
        )
    }
}
