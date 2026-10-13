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
    public override var isFlipped: Bool { true }

    public init(content: NSView, parent: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        parent.addSubview(self)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("Use init(content:parent:)") }

    public func place(_ rect: CGRect, visible: Bool, z: Int, holes: [CGRect]) {
        guard let parent = superview else { return }
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width >= 0, rect.height >= 0 else { return }
        let y = parent.isFlipped ? rect.minY : parent.bounds.height - rect.maxY
        frame = CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height)
        isHidden = !visible
        self.z = z
        self.holes = holes.filter { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }
        mask()
        (parent as? ViewOverlay)?.order()
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
