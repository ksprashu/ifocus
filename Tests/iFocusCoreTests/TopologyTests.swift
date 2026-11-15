import CoreGraphics
import Testing
@testable import iFocusCore

@Suite("Topology")
struct TopologyTests {
    @Test("T03 topology queries edges gaps negative and empty")
    func t03TopologyQueries() {
        let topo = Rig.deskThree.topology
        #expect(topo.primaryHeight == 1440)

        // Shared vertical edge x = 0 between portrait (-1152..0) and main (0..2560)
        let sharedEdgePt = CGPoint(x: 0, y: 500)
        #expect(topo.display(containing: sharedEdgePt)?.uuid == "disp-main")

        // Negative coordinates on portrait left and built-in top
        #expect(topo.display(containing: CGPoint(x: -500, y: 500))?.uuid == "disp-portrait")
        #expect(topo.display(containing: CGPoint(x: 1500, y: -500))?.uuid == "disp-builtin")

        // Gap above main and left of built-in: (500, -50)
        #expect(topo.display(containing: CGPoint(x: 500, y: -50)) == nil)
        #expect(topo.display(bestFor: CGRect(x: 400, y: -200, width: 100, height: 100)) == nil)

        // Straddling rect mostly on portrait (-100..20 across x=0)
        let straddling = CGRect(x: -100, y: 200, width: 120, height: 100)
        #expect(topo.display(bestFor: straddling)?.uuid == "disp-portrait")

        // Empty topology
        let empty = DisplayTopology.empty
        #expect(empty.primaryHeight == 0)
        #expect(empty.display(uuid: "disp-main") == nil)
        #expect(empty.display(containing: CGPoint(x: 100, y: 100)) == nil)
        #expect(empty.display(bestFor: CGRect(x: 0, y: 0, width: 500, height: 500)) == nil)
    }
}
