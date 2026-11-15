import CoreGraphics
import Testing
@testable import iFocusCore

@Suite("AXMatch")
struct AXMatchTests {
    @Test("T29 five same-PID windows match exact by windowID")
    func t29ExactMatchByWindowID() {
        let sharedBounds = CGRect(x: 1300, y: 40, width: 1240, height: 1360)
        let targets = [
            WindowDescriptor(windowID: 101, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: -1132, y: -168, width: 1112, height: 980), zIndex: 0),
            WindowDescriptor(windowID: 102, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: -1132, y: 832, width: 1112, height: 1000), zIndex: 1),
            WindowDescriptor(windowID: 103, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: 20, y: 40, width: 1240, height: 1360), zIndex: 2),
            WindowDescriptor(windowID: 104, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: sharedBounds, zIndex: 3),
            WindowDescriptor(windowID: 107, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: sharedBounds, zIndex: 4),
        ]

        let candidates = targets.reversed().enumerated().map { idx, w in
            AXWindowCandidate(index: idx, windowID: w.windowID, frame: w.bounds, isMinimized: false, subrole: "AXStandardWindow")
        }

        for (reverseIdx, w) in targets.reversed().enumerated() {
            #expect(AXWindowMatcher.match(target: w, candidates: candidates) == .exact(reverseIdx))
        }
    }

    @Test("T30 public geometric ambiguous approximate and notFound matching")
    func t30PublicMatching() {
        let target = WindowDescriptor(windowID: 500, pid: 1001, bundleID: "com.mitchellh.ghostty", bounds: CGRect(x: 100, y: 100, width: 800, height: 600), zIndex: 0)

        // 1 pt jitter matches geometric; minimized candidate skipped
        let geomCandidates = [
            AXWindowCandidate(index: 0, windowID: nil, frame: CGRect(x: 100, y: 100, width: 800, height: 600), isMinimized: true),
            AXWindowCandidate(index: 1, windowID: nil, frame: CGRect(x: 101, y: 99, width: 801, height: 599), isMinimized: false),
        ]
        #expect(AXWindowMatcher.match(target: target, candidates: geomCandidates) == .geometric(1))

        // Identical frames -> .ambiguous with lowest non-minimized AX index
        let ambigCandidates = [
            AXWindowCandidate(index: 0, windowID: nil, frame: CGRect(x: 500, y: 500, width: 400, height: 400), isMinimized: false),
            AXWindowCandidate(index: 1, windowID: nil, frame: CGRect(x: 100, y: 100, width: 800, height: 600), isMinimized: false),
            AXWindowCandidate(index: 2, windowID: nil, frame: CGRect(x: 100, y: 100, width: 800, height: 600), isMinimized: false),
        ]
        #expect(AXWindowMatcher.match(target: target, candidates: ambigCandidates) == .ambiguous(index: 1, count: 2))

        // Single candidate within 8 pt summed corner distance -> .approximate
        // Shift origin by (3, 0) with same size => |3| + 0 + |3| + 0 = 6 <= 8, max edge > 2
        let approxOne = [
            AXWindowCandidate(index: 0, windowID: nil, frame: CGRect(x: 103, y: 100, width: 800, height: 600), isMinimized: false),
        ]
        #expect(AXWindowMatcher.match(target: target, candidates: approxOne) == .approximate(0))

        // Two candidates within 8 pt summed corner distance -> .notFound (refuses ambiguous approximate)
        let approxTwo = [
            AXWindowCandidate(index: 0, windowID: nil, frame: CGRect(x: 103, y: 100, width: 800, height: 600), isMinimized: false),
            AXWindowCandidate(index: 1, windowID: nil, frame: CGRect(x: 97, y: 100, width: 800, height: 600), isMinimized: false),
        ]
        #expect(AXWindowMatcher.match(target: target, candidates: approxTwo) == .notFound)

        // Nothing within 8 pt -> .notFound
        let farAway = [
            AXWindowCandidate(index: 0, windowID: nil, frame: CGRect(x: 200, y: 200, width: 800, height: 600), isMinimized: false),
        ]
        #expect(AXWindowMatcher.match(target: target, candidates: farAway) == .notFound)
    }

    @Test("T65 non-exact matcher rejects non-nil mismatched windowIDs and matches nil-ID candidate")
    func t65NonExactIgnoresMismatchedNonNilIDs() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let target = WindowDescriptor(
            windowID: 999,
            pid: 1001,
            bundleID: "com.mitchellh.ghostty",
            bounds: frame,
            zIndex: 0
        )

        let mismatchedIDs = [
            AXWindowCandidate(index: 0, windowID: 111, frame: frame, isMinimized: false),
            AXWindowCandidate(index: 1, windowID: 222, frame: frame, isMinimized: false),
        ]
        #expect(AXWindowMatcher.match(target: target, candidates: mismatchedIDs) == .notFound)

        let mixed = [
            AXWindowCandidate(index: 0, windowID: 111, frame: frame, isMinimized: false),
            AXWindowCandidate(index: 1, windowID: nil, frame: frame, isMinimized: false),
        ]
        #expect(AXWindowMatcher.match(target: target, candidates: mixed) == .geometric(1))
    }
}
