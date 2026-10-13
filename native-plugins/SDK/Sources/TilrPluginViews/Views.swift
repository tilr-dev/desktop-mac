import AppKit

/// AppKit surfaces for any native plugin: CSS coordinates, stacking and holes.
/// No browser implementation or app-specific types belong in this module.
public final class ViewOverlay: NSView {
    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    public func order() {
        let ordered = subviews.sorted { ($0 as? ViewSurface)?.z ?? 0 < ($1 as? ViewSurface)?.z ?? 0 }
        guard !ordered.elementsEqual(subviews, by: ===) else { return }
        sortSubviews({ a, b, _ in
            let za = (a as? ViewSurface)?.z ?? 0, zb = (b as? ViewSurface)?.z ?? 0
            return za < zb ? .orderedAscending : za > zb ? .orderedDescending : .orderedSame
        }, context: nil)
    }
}

public final class ViewSurface: NSView {
    public private(set) var z = 0
    private var holes: [CGRect] = []
    /// What the content shows: placed and neither off the parent's bounds nor under its holes.
    public private(set) var shown = false
    /// Seconds between size changes passed on to the content while the rect keeps changing
    /// (a live resize); the last size is always applied once the interval has passed. 0: at once.
    /// The surface itself follows every rect, clipping the content, which stays anchored top left.
    public var resizeInterval: TimeInterval = 0
    private let content: NSView
    private var resized = Date.distantPast
    private var resizeTimer: Timer?
    public override var isFlipped: Bool { true }

    public init(content: NSView, parent: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layer?.masksToBounds = true
        content.frame = bounds
        content.autoresizingMask = []
        addSubview(content)
        parent.addSubview(self)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("Use init(content:parent:)") }

    deinit { resizeTimer?.invalidate() }

    public override func removeFromSuperview() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        super.removeFromSuperview()
    }

    public func place(_ rect: CGRect, visible: Bool, z: Int, holes: [CGRect]) {
        guard let parent = superview else { return }
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width >= 0, rect.height >= 0 else { return }
        let y = parent.isFlipped ? rect.minY : parent.bounds.height - rect.maxY
        frame = CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
        self.z = z
        self.holes = holes.filter { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }
        // Off the parent or wholly under the page's windows: hidden, so WebKit-like content
        // stops rendering (rAF, animations) instead of drawing into a fully masked layer.
        let onParent = frame.intersection(parent.bounds)
        let seen = onParent.isNull ? CGRect.null : convert(onParent, from: parent)
        shown = visible && !covered(seen, by: self.holes)
        focus(hiding: !shown)
        resize()
        mask()
        (parent as? ViewOverlay)?.order()
    }

    /// The responder inside the surface when `place` hid it, and what the window's first
    /// responder was right after (AppKit moves the focus off a hidden view).
    private weak var focusLost: NSResponder?
    private weak var focusAfter: NSResponder?

    /// Hides or shows the surface. Hiding it while it holds the focus remembers that; showing it
    /// again gives the focus back if nothing took it meanwhile (the window's first responder is
    /// still what AppKit chose when it was hidden).
    private func focus(hiding: Bool) {
        guard hiding != isHidden else { return }
        if hiding {
            let responder = window?.firstResponder as? NSView
            let inside = responder.map { $0 === self || $0.isDescendant(of: self) } ?? false
            isHidden = true
            focusLost = inside ? responder : nil
            focusAfter = inside ? window?.firstResponder : nil
            return
        }
        isHidden = false
        defer { focusLost = nil; focusAfter = nil }
        guard let lost = focusLost as? NSView, let window, lost.window === window,
              lost === self || lost.isDescendant(of: self),
              let now = window.firstResponder, now === focusAfter else { return }
        window.makeFirstResponder(lost)
    }

    /// Passes the surface's size to the content: at once when the last change is older than
    /// `resizeInterval`, else when it is (a trailing throttle). Origin changes cost nothing here.
    private func resize() {
        let size = bounds.size
        guard content.frame.size != size || content.frame.origin != .zero else {
            resizeTimer?.invalidate()
            resizeTimer = nil
            return
        }
        let wait = resized.addingTimeInterval(resizeInterval).timeIntervalSinceNow
        guard wait > 0 else {
            resizeTimer?.invalidate()
            resizeTimer = nil
            resized = Date()
            content.frame = CGRect(origin: .zero, size: size)
            return
        }
        guard resizeTimer == nil else { return }
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.resizeTimer = nil
            self.resize()
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }

    public override func layout() { super.layout(); mask() }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        if holes.contains(where: { $0.contains(convert(point, from: superview)) }) { return nil }
        return super.hitTest(point)
    }

    /// The holes, bounds and flip the mask was last built for; unchanged input skips the layers.
    private var masked: (holes: [CGRect], bounds: CGRect, flipped: Bool)?

    private func mask() {
        guard let layer else { return }
        // Standalone layers animate implicitly (0.25 s): the hole would trail a moving float.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !holes.isEmpty else {
            masked = nil
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let bounds = layer.bounds
        let flipped = layer.isGeometryFlipped || layer.contentsAreFlipped()
        if let masked, layer.mask is CAShapeLayer, masked.holes == holes, masked.bounds == bounds, masked.flipped == flipped { return }
        let shape = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        if shape.frame != bounds { shape.frame = bounds }
        shape.fillRule = .evenOdd
        let path = CGMutablePath()
        path.addRect(bounds)
        let rects = holes.map { hole in
            (flipped ? hole : CGRect(x: hole.minX, y: bounds.height - hole.maxY, width: hole.width, height: hole.height)).intersection(bounds)
        }
        for rect in disjoint(rects) { path.addRect(rect) }
        shape.path = path
        if layer.mask !== shape { layer.mask = shape }
        masked = (holes, bounds, flipped)
    }
}

/// Union without overlapping pieces, for even-odd masks.
public func disjoint(_ rects: [CGRect]) -> [CGRect] {
    var out: [CGRect] = []
    for rect in rects where !rect.isEmpty {
        var pieces = [rect]
        for taken in out {
            pieces = pieces.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(taken)
                if cut.isNull || cut.isEmpty { return [piece] }
                return [
                    CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                    CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                    CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height),
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }
        out += pieces
    }
    return out
}

/// Whether `holes` cover all of `area` (all in one coordinate space); an empty or null area is
/// covered. Exact for any number of overlapping holes: the area of their disjoint union.
public func covered(_ area: CGRect, by holes: [CGRect]) -> Bool {
    guard !area.isNull, area.width > 0, area.height > 0 else { return true }
    let clipped = holes.map { $0.intersection(area) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    guard !clipped.isEmpty else { return false }
    let total = disjoint(clipped).reduce(0) { $0 + $1.width * $1.height }
    // Float sums of exact pieces: allow a rounding error far below one pixel.
    return total >= area.width * area.height - 1e-6 * max(1, area.width * area.height)
}
