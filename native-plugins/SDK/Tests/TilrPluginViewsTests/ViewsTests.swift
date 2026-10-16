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

    func testCoveredByUnionOfHoles() {
        let area = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertTrue(covered(area, by: [CGRect(x: -10, y: -10, width: 300, height: 200)]))
        // Two side-by-side floats, overlapping, each smaller than the view.
        XCTAssertTrue(covered(area, by: [CGRect(x: 0, y: 0, width: 110, height: 100), CGRect(x: 100, y: -5, width: 120, height: 110)]))
        // Four tiles of holes meeting exactly at their edges.
        XCTAssertTrue(covered(area, by: [CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 100, y: 0, width: 100, height: 50),
                                         CGRect(x: 0, y: 50, width: 100, height: 50), CGRect(x: 100, y: 50, width: 100, height: 50)]))
        // A one-point gap between them is not covered; large overlapping holes do not overcount.
        XCTAssertFalse(covered(area, by: [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 101, y: 0, width: 100, height: 100)]))
        XCTAssertFalse(covered(area, by: [CGRect(x: 0, y: 0, width: 150, height: 100), CGRect(x: 0, y: 0, width: 150, height: 100),
                                          CGRect(x: 10, y: 0, width: 150, height: 100)]))
        XCTAssertFalse(covered(area, by: []))
        XCTAssertTrue(covered(.null, by: []))
    }

    @MainActor
    func testCoveredOrOffParentSurfaceIsHidden() {
        let overlay = ViewOverlay(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let surface = ViewSurface(content: NSView(), parent: overlay)
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        surface.place(rect, visible: true, z: 0, holes: [CGRect(x: 0, y: 0, width: 110, height: 100)])
        XCTAssertFalse(surface.isHidden, "a partial cover keeps the view, masked")
        XCTAssertNotNil(surface.layer?.mask)
        surface.place(rect, visible: true, z: 0, holes: [CGRect(x: 0, y: 0, width: 110, height: 100), CGRect(x: 105, y: 0, width: 95, height: 100)])
        XCTAssertTrue(surface.isHidden, "two floats side by side cover it")
        surface.place(rect, visible: true, z: 0, holes: [])
        XCTAssertFalse(surface.isHidden)
        surface.place(CGRect(x: 700, y: 0, width: 200, height: 100), visible: true, z: 0, holes: [])
        XCTAssertTrue(surface.isHidden, "off the parent")
        // Only the part on the parent needs covering.
        surface.place(CGRect(x: 500, y: 0, width: 200, height: 100), visible: true, z: 0, holes: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        XCTAssertTrue(surface.isHidden)
        surface.place(CGRect(x: 0, y: 0, width: 0, height: 100), visible: true, z: 0, holes: [])
        XCTAssertTrue(surface.isHidden, "empty")
    }

    @MainActor
    func testSizeChangesAreThrottledAndTheLastOneApplied() {
        let overlay = ViewOverlay(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let content = NSView()
        let surface = ViewSurface(content: content, parent: overlay)
        surface.resizeInterval = 0.1
        surface.place(CGRect(x: 0, y: 0, width: 300, height: 200), visible: true, z: 0, holes: [])
        XCTAssertEqual(content.frame, CGRect(x: 0, y: 0, width: 300, height: 200), "the first size applies at once")
        for width in stride(from: 290, through: 200, by: -10) {
            surface.place(CGRect(x: 10, y: 0, width: CGFloat(width), height: 200), visible: true, z: 0, holes: [])
        }
        XCTAssertEqual(surface.frame, CGRect(x: 10, y: 0, width: 200, height: 200), "the surface follows every rect")
        XCTAssertEqual(content.frame.size, CGSize(width: 300, height: 200), "the content keeps its size until the interval passes")
        XCTAssertEqual(content.frame.origin, .zero, "anchored top left")
        surface.place(CGRect(x: 50, y: 20, width: 200, height: 200), visible: true, z: 0, holes: [])
        XCTAssertEqual(surface.frame.origin, CGPoint(x: 50, y: 20), "moves apply at once")
        let applied = expectation(description: "last size applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(content.frame, CGRect(x: 0, y: 0, width: 200, height: 200))
            applied.fulfill()
        }
        wait(for: [applied], timeout: 2)
        surface.resizeInterval = 0
        surface.place(CGRect(x: 0, y: 0, width: 120, height: 80), visible: true, z: 0, holes: [])
        XCTAssertEqual(content.frame.size, CGSize(width: 120, height: 80), "0: every change at once")
    }

    /// A focusable stand-in for a web view.
    private final class Focusable: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @MainActor
    func testFocusComesBackWhenUncovered() {
        let overlay = ViewOverlay(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: overlay.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = overlay
        let content = Focusable()
        let surface = ViewSurface(content: content, parent: overlay)
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let cover = [CGRect(x: -10, y: -10, width: 300, height: 200)]
        surface.place(rect, visible: true, z: 0, holes: [])
        XCTAssertTrue(window.makeFirstResponder(content))
        surface.place(rect, visible: true, z: 0, holes: cover)
        XCTAssertTrue(surface.isHidden)
        XCTAssertFalse(window.firstResponder === content)
        surface.place(rect, visible: true, z: 0, holes: [])
        XCTAssertTrue(window.firstResponder === content, "the focus comes back when the surface is uncovered")

        // Another view took the focus while the surface was covered: it keeps it.
        let other = Focusable()
        overlay.addSubview(other)
        surface.place(rect, visible: true, z: 0, holes: cover)
        XCTAssertTrue(window.makeFirstResponder(other))
        surface.place(rect, visible: true, z: 0, holes: [])
        XCTAssertTrue(window.firstResponder === other)

        // Hidden without the focus: shown, it takes none.
        surface.place(rect, visible: false, z: 0, holes: [])
        surface.place(rect, visible: true, z: 0, holes: [])
        XCTAssertTrue(window.firstResponder === other)
    }
}
