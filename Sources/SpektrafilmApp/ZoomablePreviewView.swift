#if os(macOS)
import AppKit
import SwiftUI
import Metal
import QuartzCore
import SpektrafilmCore
import SpektrafilmPreviewGeometry

/// A rendered full-resolution detail tile. `sourceRect` is expressed in original
/// source-image pixels (top-left origin), not in proxy-preview pixels.
/// `rendered == true` is a chemistry-rendered tile ("after"); `false` is the
/// unedited source tile ("before") used by the compare modes.
struct PreviewDetailTile {
    let image: NSImage?
    let texture: MTLTexture?
    let sourceRect: CGRect
    let rendered: Bool

    init(image: NSImage, sourceRect: CGRect, rendered: Bool) {
        self.image = image; self.texture = nil; self.sourceRect = sourceRect; self.rendered = rendered
    }
    init(texture: MTLTexture, sourceRect: CGRect, rendered: Bool) {
        self.image = nil; self.texture = texture; self.sourceRect = sourceRect; self.rendered = rendered
    }
}

/// macOS-native photographic inspection canvas.
///
/// Fit/low magnifications draw the inexpensive navigation/fallback proxy image
/// across the original source geometry. At higher magnifications the canvas
/// publishes a canonical `PreviewGeometry` so the render scheduler can produce
/// a progressive viewport ROI texture. The canvas, view-model scheduler, and
/// Metal overlay all consume the same `PreviewGeometry` — no independent
/// geometry calculations exist anywhere in the preview pipeline.
struct ZoomablePreviewView: NSViewRepresentable {
    let image: NSImage
    let sourcePixelSize: CGSize
    let detailTiles: [PreviewDetailTile]
    let comparisonImage: NSImage?
    let comparisonSliderActive: Bool
    let backgroundColor: NSColor
    @Binding var requestedScale: CGFloat?
    /// Called with the canonical geometry whenever the viewport changes
    /// (pan, zoom, resize, source size change, backing scale change).
    let onGeometryChanged: (PreviewGeometry) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(requestedScale: $requestedScale) }

    func makeNSView(context: Context) -> ZoomableImageCanvas {
        let view = ZoomableImageCanvas()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Photo preview")
        view.setAccessibilityIdentifier("preview.image")
        view.setImagePreservingViewport(image)
        view.setSourcePixelSize(sourcePixelSize)
        view.setDetailTiles(detailTiles)
        view.setComparison(image: comparisonImage, active: comparisonSliderActive)
        view.setBackgroundColor(backgroundColor)
        view.onScaleChanged = { scale in context.coordinator.setScaleFromCanvas(scale) }
        view.onGeometryChanged = onGeometryChanged
        view.applyRequestedScale(requestedScale, force: true)
        return view
    }

    func updateNSView(_ nsView: ZoomableImageCanvas, context: Context) {
        context.coordinator.requestedScale = $requestedScale
        nsView.onScaleChanged = { scale in context.coordinator.setScaleFromCanvas(scale) }
        nsView.onGeometryChanged = onGeometryChanged
        nsView.setSourcePixelSize(sourcePixelSize)
        nsView.setDetailTiles(detailTiles)
        nsView.setComparison(image: comparisonImage, active: comparisonSliderActive)
        nsView.setBackgroundColor(backgroundColor)
        nsView.setImagePreservingViewport(image)
        nsView.applyRequestedScale(requestedScale)
    }

    @MainActor final class Coordinator {
        var requestedScale: Binding<CGFloat?>
        init(requestedScale: Binding<CGFloat?>) { self.requestedScale = requestedScale }
        func setScaleFromCanvas(_ scale: CGFloat?) {
            let current = requestedScale.wrappedValue
            switch (current, scale) {
            case (nil, nil): return
            case let (a?, b?) where abs(a - b) < 0.000_1: return
            default: requestedScale.wrappedValue = scale
            }
        }
    }
}

@MainActor
final class ZoomableImageCanvas: NSView {
    private(set) var image: NSImage? { didSet { needsDisplay = true } }
    private(set) var sourcePixelSize: CGSize = .zero
    private(set) var detailTiles: [PreviewDetailTile] = []
    private var comparisonImage: NSImage?
    private var comparisonSliderActive = false
    private var comparisonFraction: CGFloat = 0.5
    private var draggingComparisonDivider = false
    private let metalOverlay = MetalDetailTileOverlayView()

    /// nil = Fit; non-nil = absolute image scale (1 == 100%).
    private(set) var scale: CGFloat?
    private var pan = CGPoint.zero
    private var dragStartPan = CGPoint.zero
    private var dragStartPoint = CGPoint.zero
    private var externalScaleMarker: CGFloat?? = nil

    /// The canonical geometry, recalculated whenever inputs change. This is
    /// the single source of truth for the image frame, mat, fit scale, pan
    /// limits, visible source ROI, and required render resolution.
    private(set) var geometry: PreviewGeometry? = nil
    private var geometryNotificationPending = false
    private var lastNotifiedGeometry: PreviewGeometry? = nil

    var onScaleChanged: ((CGFloat?) -> Void)?
    var onGeometryChanged: ((PreviewGeometry) -> Void)?

    private var backgroundColor = NSColor(srgbRed: 0.466, green: 0.466, blue: 0.466, alpha: 1)
    /// Thin neutral hairline drawn at the photo edge, outside the ROI.
    private let hairlineColor = NSColor(srgbRed: 0.35, green: 0.35, blue: 0.35, alpha: 1)
    private let hairlineWidth: CGFloat = 1.5
    private let minScale: CGFloat = 0.05
    private let maxScale: CGFloat = 16

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.masksToBounds = true; allowedTouchTypes = [.indirect]
        addSubview(metalOverlay); metalOverlay.frame = bounds; metalOverlay.autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true; layer?.masksToBounds = true; allowedTouchTypes = [.indirect]
        addSubview(metalOverlay); metalOverlay.frame = bounds; metalOverlay.autoresizingMask = [.width, .height]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true
    }

    func setImagePreservingViewport(_ newImage: NSImage) {
        guard image !== newImage else { return }
        image = newImage
        recalculateGeometryAndNotify()
        // Image pixels changed, but the viewport did not. Do not feed a model
        // update back into SwiftUI simply because a new render arrived.
    }

    func setSourcePixelSize(_ newSize: CGSize) {
        guard abs(sourcePixelSize.width - newSize.width) >= 0.5 || abs(sourcePixelSize.height - newSize.height) >= 0.5 else { return }
        sourcePixelSize = newSize
        recalculateGeometryAndNotify()
        // Source geometry genuinely changed, so the visible source rectangle
        // may have changed even with the same pan/zoom.
    }

    func setComparison(image: NSImage?, active: Bool) {
        let imageChanged = comparisonImage !== image
        let becameActive = active && !comparisonSliderActive
        comparisonImage = image
        comparisonSliderActive = active
        if becameActive { comparisonFraction = 0.5 }
        if imageChanged || becameActive || !active { needsDisplay = true }
        updateMetalOverlay()
    }

    func setBackgroundColor(_ color: NSColor) {
        if backgroundColor != color {
            backgroundColor = color
            needsDisplay = true
        }
    }

    func setDetailTiles(_ newTiles: [PreviewDetailTile]) {
        guard !Self.sameTiles(detailTiles, newTiles) else { return }
        detailTiles = newTiles
        needsDisplay = true
        updateMetalOverlay()
        // Tile arrivals only affect presentation. They must never generate a
        // new viewport request or they create a SwiftUI ↔ AppKit feedback loop.
    }

    func applyRequestedScale(_ requested: CGFloat?, force: Bool = false) {
        if !force, let marker = externalScaleMarker, scalesEqual(marker, requested) { return }
        externalScaleMarker = .some(requested)
        if let requested { scale = clampScale(requested) }
        else { scale = nil; pan = .zero }
        recalculateGeometryAndNotify()
    }

    override func layout() {
        super.layout()
        recalculateGeometryAndNotify()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Assessment background: neutral surround (gray, black, or white).
        backgroundColor.setFill(); dirtyRect.fill()

        guard let image, let geo = geometry else { return }

        // ISO-style white mat ring. Gray assessment background remains visible
        // outside matBounds at every zoom level.
        NSColor.white.setFill(); geo.matBounds.fill()

        // The photograph lives inside a permanent aperture. This clip is the
        // key behavior: zooming/panning can make imageFrame arbitrarily large,
        // but it can never cover the white mat or gray assessment surround.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: geo.contentBounds).addClip()

        let hairlineRect = geo.imageFrame.insetBy(dx: -hairlineWidth, dy: -hairlineWidth)
        hairlineColor.setFill(); hairlineRect.fill()
        NSColor.white.setFill(); geo.imageFrame.fill()

        image.draw(in: geo.imageFrame, from: .zero, operation: .copy, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

        // Slider comparison uses the exact same canonical image frame as the
        // rendered preview. Only the left side is clipped to the original.
        if comparisonSliderActive, let before = comparisonImage {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: comparisonLeftClipRect(geometry: geo)).addClip()
            before.draw(in: geo.imageFrame, from: .zero, operation: .copy, fraction: 1,
                        respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()

        if !detailTiles.isEmpty {
            let tileClip = geo.contentBounds.intersection(bounds)
            if comparisonSliderActive {
                // Sharp "before" (original) tiles on the left, sharp "after"
                // (chemistry) tiles on the right, split at the divider.
                let dividerX = comparisonDividerX(geometry: geo)
                let leftClip = CGRect(x: tileClip.minX, y: tileClip.minY,
                                      width: max(0, dividerX - tileClip.minX), height: tileClip.height)
                let rightClip = CGRect(x: dividerX, y: tileClip.minY,
                                       width: max(0, tileClip.maxX - dividerX), height: tileClip.height)
                drawDetailTiles(detailTiles.filter { !$0.rendered }, clippedTo: leftClip, geometry: geo)
                drawDetailTiles(detailTiles.filter { $0.rendered }, clippedTo: rightClip, geometry: geo)
            } else {
                drawDetailTiles(detailTiles, clippedTo: tileClip, geometry: geo)
            }
        }

        if comparisonSliderActive, comparisonImage != nil {
            drawComparisonChrome(geometry: geo)
        }
    }

    private func drawDetailTiles(_ tiles: [PreviewDetailTile], clippedTo clip: CGRect, geometry geo: PreviewGeometry) {
        guard !clip.isNull, clip.width > 0, clip.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip).addClip()
        for tile in tiles where tile.sourceRect.width > 0 && tile.sourceRect.height > 0 {
            let tileRect = geo.screenRect(forSourceRect: tile.sourceRect)
            tile.image?.draw(in: tileRect, from: .zero, operation: .copy, fraction: 1,
                             respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func comparisonDividerX(geometry: PreviewGeometry) -> CGFloat {
        geometry.contentBounds.minX + geometry.contentBounds.width * comparisonFraction
    }

    private func comparisonLeftClipRect(geometry: PreviewGeometry) -> CGRect {
        let x = comparisonDividerX(geometry: geometry)
        return CGRect(x: geometry.contentBounds.minX, y: geometry.contentBounds.minY,
                      width: max(0, x - geometry.contentBounds.minX), height: geometry.contentBounds.height)
    }

    private func drawComparisonChrome(geometry geo: PreviewGeometry) {
        let x = comparisonDividerX(geometry: geo)
        let visible = geo.contentBounds.intersection(bounds)
        guard !visible.isNull else { return }
        NSColor.white.withAlphaComponent(0.95).setFill()
        CGRect(x: x - 1, y: visible.minY, width: 2, height: visible.height).fill()

        let handle = NSBezierPath(ovalIn: CGRect(x: x - 8, y: visible.midY - 8, width: 16, height: 16))
        NSColor.black.withAlphaComponent(0.45).setFill(); handle.fill()
        let inner = NSBezierPath(ovalIn: CGRect(x: x - 5.5, y: visible.midY - 5.5, width: 11, height: 11))
        NSColor.white.setFill(); inner.fill()

        drawComparisonLabel("BEFORE", at: CGPoint(x: visible.minX + 12, y: visible.minY + 12), alignRight: false)
        drawComparisonLabel("AFTER", at: CGPoint(x: visible.maxX - 12, y: visible.minY + 12), alignRight: true)
    }

    private func drawComparisonLabel(_ text: String, at point: CGPoint, alignRight: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 7, padY: CGFloat = 4
        let x = alignRight ? point.x - size.width - padX * 2 : point.x
        let rect = CGRect(x: x, y: point.y, width: size.width + padX * 2, height: size.height + padY * 2)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + padX, y: rect.minY + padY), withAttributes: attrs)
    }

    private func updateMetalOverlay() {
        guard let geo = geometry else { metalOverlay.update(tiles: [], geometry: nil, comparisonDividerX: nil); return }
        metalOverlay.update(
            tiles: detailTiles.filter { $0.texture != nil },
            geometry: geo,
            comparisonDividerX: comparisonSliderActive ? comparisonDividerX(geometry: geo) : nil
        )
    }

    // MARK: - Canonical geometry calculation

    /// Recalculate the canonical geometry from current canvas state and notify
    /// the view model if it changed meaningfully. The geometry is the single
    /// source of truth used by drawing, the render scheduler, and the Metal
    /// overlay.
    private func recalculateGeometryAndNotify() {
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            geometry = nil
            return
        }
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let zoom: CGFloat = {
            guard let s = scale else { return 1 }
            // zoom is relative to Fit; scale is absolute. We need fitScale
            // first, so compute it in the same pass.
            let fit = PreviewGeometryCalculator.calculate(
                viewportBounds: CGRect(origin: .zero, size: bounds.size),
                sourceSize: sourcePixelSize, zoom: 1, pan: .zero,
                backingScale: backingScale, matInset: 0
            ).fitScale
            return fit > 0 ? s / fit : 1
        }()

        let geo = PreviewGeometryCalculator.calculate(
            viewportBounds: CGRect(origin: .zero, size: bounds.size),
            sourceSize: sourcePixelSize,
            zoom: zoom,
            pan: pan,
            backingScale: backingScale,
            matInset: 0 // use default mat policy
        )
        geometry = geo
        // Adopt the clamped pan so the gesture state stays in sync with limits.
        pan = geo.pan
        needsDisplay = true
        updateMetalOverlay()
        scheduleGeometryNotification()
    }

    private func scheduleGeometryNotification() {
        guard !geometryNotificationPending, geometry != nil else { return }
        geometryNotificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryNotificationPending = false
            guard let current = self.geometry else { return }
            if let last = self.lastNotifiedGeometry,
               PreviewGeometry.approximatelyEqual(last, current) {
                return
            }
            self.lastNotifiedGeometry = current
            self.onGeometryChanged?(current)
        }
    }

    // MARK: interaction
    override func magnify(with event: NSEvent) {
        zoom(by: max(0.05, 1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 { toggleFitAndOneToOne(); return }
        let point = convert(event.locationInWindow, from: nil)
        if comparisonSliderActive, let geo = geometry,
           abs(point.x - comparisonDividerX(geometry: geo)) <= 12,
           geo.contentBounds.contains(point) {
            draggingComparisonDivider = true
            updateComparisonFraction(at: point.x, geometry: geo)
            return
        }
        dragStartPan = pan; dragStartPoint = point
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if draggingComparisonDivider, let geo = geometry {
            updateComparisonFraction(at: point.x, geometry: geo)
            return
        }
        pan.x = dragStartPan.x + point.x - dragStartPoint.x
        pan.y = dragStartPan.y + point.y - dragStartPoint.y
        recalculateGeometryAndNotify()
    }
    override func mouseUp(with event: NSEvent) {
        draggingComparisonDivider = false
        super.mouseUp(with: event)
    }
    private func updateComparisonFraction(at x: CGFloat, geometry geo: PreviewGeometry) {
        guard geo.contentBounds.width > 0 else { return }
        comparisonFraction = min(max((x - geo.contentBounds.minX) / geo.contentBounds.width, 0), 1)
        needsDisplay = true
        updateMetalOverlay()
    }
    override func scrollWheel(with event: NSEvent) {
        // Scroll pans exactly like dragging: the image follows the gesture in
        // point space (already flipped). Precise trackpad deltas map 1:1; line-
        // based mouse wheels are scaled up so a notch produces a usable pan.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        pan.x += event.scrollingDeltaX * scale
        pan.y += event.scrollingDeltaY * scale
        recalculateGeometryAndNotify()
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { cycleMiddleClickZoom() } else { super.otherMouseDown(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": setFit(); case "1": setScale(1); case "2": setScale(2)
        case "+", "=": stepZoom(direction: 1); case "-", "_": stepZoom(direction: -1)
        default: super.keyDown(with: event)
        }
    }

    // MARK: zoom
    private func zoom(by factor: CGFloat, around anchor: CGPoint) {
        guard let geo = geometry else { return }
        let oldScale = geo.imageScale, newScale = clampScale(oldScale * factor)
        guard abs(newScale - oldScale) > 0.000_001 else { return }
        let center = CGPoint(x: bounds.midX + pan.x, y: bounds.midY + pan.y)
        let anchorVector = CGPoint(x: anchor.x - center.x, y: anchor.y - center.y)
        let ratio = newScale / oldScale
        pan.x -= anchorVector.x * (ratio - 1); pan.y -= anchorVector.y * (ratio - 1)
        scale = newScale; externalScaleMarker = .some(newScale)
        // Keep the SwiftUI zoomScale binding in sync so updateNSView's
        // applyRequestedScale recognizes the canvas state and does not reset
        // the zoom/pan back to Fit on the next SwiftUI update.
        onScaleChanged?(newScale)
        recalculateGeometryAndNotify()
    }
    private func setFit() {
        scale = nil; pan = .zero; externalScaleMarker = .some(nil); onScaleChanged?(nil)
        recalculateGeometryAndNotify()
    }
    private func setScale(_ requested: CGFloat) {
        scale = clampScale(requested); pan = .zero; externalScaleMarker = .some(scale); onScaleChanged?(scale)
        recalculateGeometryAndNotify()
    }
    private func toggleFitAndOneToOne() { scale == nil ? setScale(1) : setFit() }
    private func cycleMiddleClickZoom() {
        guard let scale else { setScale(1); return }
        scale < 1.5 ? setScale(2) : setFit()
    }
    private func stepZoom(direction: Int) {
        let steps:[CGFloat] = [0.05,0.10,0.125,0.25,0.3333,0.50,0.6667,1,1.5,2,3,4,8,16]
        guard let geo = geometry else { return }
        let current = geo.imageScale
        if direction > 0 { setScale(steps.first(where:{$0 > current*1.001}) ?? maxScale) }
        else { setScale(steps.last(where:{$0 < current*0.999}) ?? minScale) }
    }

    private static func sameTiles(_ lhs: [PreviewDetailTile], _ rhs: [PreviewDetailTile]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            let sameImage = (a.image == nil && b.image == nil) || (a.image != nil && b.image != nil && a.image === b.image)
            let sameTexture = (a.texture == nil && b.texture == nil) || (a.texture != nil && b.texture != nil && a.texture === b.texture)
            if !sameImage || !sameTexture || a.rendered != b.rendered || !PreviewGeometry.rectApproximatelyEqual(a.sourceRect, b.sourceRect, epsilon: 0.5) { return false }
        }
        return true
    }

    private func clampScale(_ v:CGFloat)->CGFloat { min(max(v,minScale),maxScale) }
    private func scalesEqual(_ a:CGFloat?,_ b:CGFloat?)->Bool {
        switch(a,b){case(nil,nil):return true;case let(x?,y?):return abs(x-y)<0.000_001;default:return false}
    }
}

@MainActor
final class MetalDetailTileOverlayView: NSView {
    private struct Vertex { var position: SIMD2<Float>; var uv: SIMD2<Float> }
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private var tiles: [PreviewDetailTile] = []
    private var geometry: PreviewGeometry?
    private var comparisonDividerX: CGFloat?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    override init(frame frameRect: NSRect) {
        let d = MTLCreateSystemDefaultDevice(); device = d; queue = d?.makeCommandQueue()
        if let d {
            do {
                let library = try d.makeLibrary(source: Self.shader, options: nil)
                let desc = MTLRenderPipelineDescriptor(); desc.vertexFunction = library.makeFunction(name: "tile_vertex"); desc.fragmentFunction = library.makeFunction(name: "tile_fragment"); desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                desc.colorAttachments[0].isBlendingEnabled = true
                desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                desc.colorAttachments[0].sourceAlphaBlendFactor = .one; desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipeline = try d.makeRenderPipelineState(descriptor: desc)
            } catch { pipeline = nil; AppLog.warning("app", "Metal detail overlay pipeline failed: \(error)") }
        } else { pipeline = nil }
        super.init(frame: frameRect)
        wantsLayer = true
        if let metal = layer as? CAMetalLayer { metal.device = d; metal.pixelFormat = .bgra8Unorm; metal.isOpaque = false; metal.framebufferOnly = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if let metal = layer as? CAMetalLayer {
            metal.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            metal.drawableSize = CGSize(width: max(bounds.width * metal.contentsScale, 1), height: max(bounds.height * metal.contentsScale, 1))
        }
        render()
    }

    /// Update the overlay from the canonical geometry. The overlay no longer
    /// derives tile positions independently — it maps source rects through
    /// `geometry.screenRect(forSourceRect:)`. When `comparisonDividerX` is set,
    /// unedited (`rendered == false`) tiles are clipped left of the divider and
    /// chemistry tiles right of it.
    func update(tiles: [PreviewDetailTile], geometry: PreviewGeometry?, comparisonDividerX: CGFloat?) {
        self.tiles = tiles; self.geometry = geometry; self.comparisonDividerX = comparisonDividerX; render()
    }

    private func render() {
        guard bounds.width > 0, bounds.height > 0,
              let geo = geometry,
              let layer = layer as? CAMetalLayer,
              let drawable = layer.nextDrawable(),
              let queue, let pipeline,
              let cb = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = drawable.texture; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        for tile in tiles {
            guard let texture = tile.texture else { continue }
            var r = geo.screenRect(forSourceRect: tile.sourceRect).intersection(geo.contentBounds).intersection(bounds)
            if let dividerX = comparisonDividerX {
                if tile.rendered {
                    r = r.intersection(CGRect(x: dividerX, y: 0, width: max(0, bounds.maxX - dividerX), height: bounds.height))
                } else {
                    r = r.intersection(CGRect(x: 0, y: 0, width: max(0, dividerX), height: bounds.height))
                }
            }
            if r.isNull || r.width <= 0 || r.height <= 0 { continue }
            let l = Float(2 * r.minX / bounds.width - 1), rr = Float(2 * r.maxX / bounds.width - 1)
            let t = Float(1 - 2 * r.minY / bounds.height), b = Float(1 - 2 * r.maxY / bounds.height)
            let vertices = [Vertex(position: SIMD2(l,t), uv: SIMD2(0,0)), Vertex(position: SIMD2(l,b), uv: SIMD2(0,1)), Vertex(position: SIMD2(rr,t), uv: SIMD2(1,0)), Vertex(position: SIMD2(rr,b), uv: SIMD2(1,1))]
            vertices.withUnsafeBytes { raw in enc.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0) }
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding(); cb.present(drawable); cb.commit()
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct V { float2 position; float2 uv; };
    struct O { float4 position [[position]]; float2 uv; };
    vertex O tile_vertex(const device V* v [[buffer(0)]], uint id [[vertex_id]]) { O o; o.position=float4(v[id].position,0,1); o.uv=v[id].uv; return o; }
    fragment float4 tile_fragment(O in [[stage_in]], texture2d<float> tex [[texture(0)]]) { constexpr sampler s(address::clamp_to_edge, filter::linear); return float4(tex.sample(s,in.uv).rgb,1); }
    """#
}

extension CGRect {
    func centerDistanceSquared(to point: CGPoint) -> CGFloat {
        let dx = midX - point.x
        let dy = midY - point.y
        return dx * dx + dy * dy
    }
}
#endif
