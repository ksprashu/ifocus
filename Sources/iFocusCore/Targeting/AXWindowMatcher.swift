import CoreGraphics
import Foundation

public enum AXWindowMatcher {
    public static func match(
        target: WindowDescriptor,
        candidates: [AXWindowCandidate]
    ) -> AXMatch {
        if let exact = candidates.first(where: { $0.windowID == target.windowID }) {
            return .exact(exact.index)
        }

        let eligible = candidates.filter { $0.windowID == nil && !$0.isMinimized && $0.frame != nil }

        let geometric = eligible.filter { candidate in
            guard let frame = candidate.frame else { return false }
            return edgesWithin(frame, target.bounds, tolerance: 2.0)
        }

        if geometric.count == 1 {
            return .geometric(geometric[0].index)
        }
        if geometric.count > 1 {
            let lowestIndex = geometric.map(\.index).min() ?? geometric[0].index
            return .ambiguous(index: lowestIndex, count: geometric.count)
        }

        let approximate = eligible.filter { candidate in
            guard let frame = candidate.frame else { return false }
            return summedCornerDistance(frame, target.bounds) <= 8.0
        }

        if approximate.count == 1 {
            return .approximate(approximate[0].index)
        }

        return .notFound
    }

    public static func edgesWithin(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance
            && abs(a.maxY - b.maxY) <= tolerance
    }

    public static func summedCornerDistance(_ a: CGRect, _ b: CGRect) -> Double {
        Double(
            abs(a.minX - b.minX)
                + abs(a.minY - b.minY)
                + abs(a.maxX - b.maxX)
                + abs(a.maxY - b.maxY)
        )
    }
}
