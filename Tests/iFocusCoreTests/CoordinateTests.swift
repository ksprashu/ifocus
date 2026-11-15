import CoreGraphics
import Testing
@testable import iFocusCore

@Suite("Coordinates")
struct CoordinateTests {
    @Test("T01 quartz cocoa roundtrip across deskThree")
    func t01RoundtripAcrossDeskThree() {
        let topology = Rig.deskThree.topology
        let primaryHeight = topology.primaryHeight
        #expect(primaryHeight == 1440)

        let rects = [
            CGRect(x: 20, y: 40, width: 1240, height: 1360),       // main
            CGRect(x: 1200, y: -1060, width: 1600, height: 1000),  // built-in (negative y)
            CGRect(x: -1132, y: -168, width: 1112, height: 980),   // portrait (negative x & y)
            CGRect(x: -1132, y: 832, width: 1112, height: 1000),   // portrait lower
        ]

        for r in rects {
            let cocoa = CoordinateSpace.cocoaRect(fromQuartz: r, primaryHeight: primaryHeight)
            let roundtrip = CoordinateSpace.quartzRect(fromCocoa: cocoa, primaryHeight: primaryHeight)
            #expect(abs(roundtrip.origin.x - r.origin.x) < 1e-6)
            #expect(abs(roundtrip.origin.y - r.origin.y) < 1e-6)
            #expect(abs(roundtrip.width - r.width) < 1e-6)
            #expect(abs(roundtrip.height - r.height) < 1e-6)
        }
    }

    @Test("T02 built-in panel flips using primary height")
    func t02BuiltinFlipsUsingPrimaryHeight() {
        let primaryHeight: CGFloat = 1440
        // Built-in rect: origin (1200, -1000), size (400, 300) => maxY = -700
        // Cocoa y = primaryHeight - maxY = 1440 - (-700) = 2140 (NOT 1117 - (-700) = 1817)
        let quartz = CGRect(x: 1200, y: -1000, width: 400, height: 300)
        let cocoa = CoordinateSpace.cocoaRect(fromQuartz: quartz, primaryHeight: primaryHeight)
        #expect(cocoa.origin.x == 1200)
        #expect(cocoa.origin.y == 2140)
        #expect(cocoa.width == 400)
        #expect(cocoa.height == 300)
    }
}
