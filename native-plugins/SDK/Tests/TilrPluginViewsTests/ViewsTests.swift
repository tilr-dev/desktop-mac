import XCTest
import AppKit
@testable import TilrPluginViews

final class ViewsTests: XCTestCase {
    func testOverlappingHolesStayOpen() {
        let holes = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 5, y: 5, width: 10, height: 10)]
        let pieces = disjoint(holes)
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.width * $1.height }, 175)
        for (i, a) in pieces.enumerated() {
            for b in pieces.dropFirst(i + 1) { XCTAssertTrue(a.intersection(b).isEmpty) }
        }
        XCTAssertEqual(pieces.filter { $0.contains(CGPoint(x: 7, y: 7)) }.count, 1)
    }

    @MainActor
    func testSurfacePlacementAndHitTesting() {
        let overlay = ViewOverlay(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let view = NSView()
        let surface = ViewSurface(content: view, parent: overlay)
        surface.place(CGRect(x: 20, y: 30, width: 200, height: 100), visible: true, z: 2,
                      holes: [CGRect(x: 10, y: 10, width: 20, height: 20)])
        XCTAssertEqual(surface.frame.origin, CGPoint(x: 20, y: 30))
        XCTAssertNil(surface.hitTest(CGPoint(x: 35, y: 45)))
        XCTAssertNotNil(surface.hitTest(CGPoint(x: 80, y: 80)))
        XCTAssertNil(overlay.hitTest(CGPoint(x: 500, y: 300)))
        surface.place(CGRect(x: 0, y: 0, width: 100, height: 100), visible: false, z: 0, holes: [])
        XCTAssertTrue(surface.isHidden)
    }

    @MainActor
    func testMaskIsNotAnimatedAndReusedWhenUnchanged() throws {
        let overlay = ViewOverlay(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let surface = ViewSurface(content: NSView(), parent: overlay)
        let holes = [CGRect(x: 10, y: 10, width: 20, height: 20)]
        surface.place(CGRect(x: 0, y: 0, width: 200, height: 100), visible: true, z: 0, holes: holes)
        let shape = try XCTUnwrap(surface.layer?.mask as? CAShapeLayer)
        let path = shape.path
        surface.place(CGRect(x: 50, y: 0, width: 200, height: 100), visible: true, z: 0, holes: holes)
        XCTAssertTrue(surface.layer?.mask === shape)
        XCTAssertTrue(shape.path === path, "same holes and bounds keep the mask untouched")
        surface.place(CGRect(x: 50, y: 0, width: 200, height: 100), visible: true, z: 0,
                      holes: [CGRect(x: 40, y: 10, width: 20, height: 20)])
        XCTAssertFalse(shape.path === path)
        XCTAssertNil(shape.animationKeys(), "hole changes apply at once")
        surface.place(CGRect(x: 50, y: 0, width: 200, height: 100), visible: true, z: 0, holes: [])
        XCTAssertNil(surface.layer?.mask)
    }
}
