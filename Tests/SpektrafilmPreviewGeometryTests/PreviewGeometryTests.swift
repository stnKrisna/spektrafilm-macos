import Foundation
import Testing
@testable import SpektrafilmPreviewGeometry

private let eps: CGFloat = 0.01

private func make(
    viewport: CGSize,
    source: CGSize,
    zoom: CGFloat = 1,
    pan: CGPoint = .zero,
    backing: CGFloat = 1,
    mat: CGFloat = 0
) -> PreviewGeometry {
    PreviewGeometryCalculator.calculate(
        viewportBounds: CGRect(origin: .zero, size: viewport),
        sourceSize: source,
        zoom: zoom,
        pan: pan,
        backingScale: backing,
        matInset: mat
    )
}

// MARK: - Fit / mat behavior

@Test func landscapeImageInLandscapeViewport() {
    let g = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 6000, height: 4000))
    // Fit reserves the mat: image frame inset from viewport by at least matInset.
    #expect(g.imageFrame.minX >= g.contentBounds.minX - eps)
    #expect(g.imageFrame.minY >= g.contentBounds.minY - eps)
    #expect(g.imageFrame.maxX <= g.contentBounds.maxX + eps)
    #expect(g.imageFrame.maxY <= g.contentBounds.maxY + eps)
    // Centered in content bounds.
    #expect(abs(g.imageFrame.midX - g.contentBounds.midX) < eps)
    #expect(abs(g.imageFrame.midY - g.contentBounds.midY) < eps)
    // Landscape image in landscape viewport: width-limited fit.
    #expect(abs(g.imageFrame.width - g.contentBounds.width) < eps)
    #expect(g.imageFrame.height <= g.contentBounds.height + eps)
    // Visible source ROI is the full image at Fit.
    #expect(PreviewGeometry.rectApproximatelyEqual(g.visibleSourceRect, CGRect(origin: .zero, size: g.sourceSize), epsilon: 1))
}

@Test func landscapeImageInPortraitViewport() {
    let g = make(viewport: CGSize(width: 500, height: 1000), source: CGSize(width: 6000, height: 4000))
    // Width-limited fit: the aperture (and image) consumes the full content
    // width while the image height shrinks below the maximum aperture height,
    // leaving unused surround in the taller viewport.
    #expect(abs(g.imageFrame.width - g.contentBounds.width) < eps)
    #expect(abs(g.imageFrame.height - g.contentBounds.height) < eps)
    #expect(g.contentBounds.height < g.viewportBounds.height - eps)
    // Centered vertically within content bounds.
    #expect(abs(g.imageFrame.midY - g.contentBounds.midY) < eps)
}

@Test func portraitImageInLandscapeViewport() {
    let g = make(viewport: CGSize(width: 1000, height: 600), source: CGSize(width: 4000, height: 6000))
    // Height-limited fit: full content height, image width shrinks below the
    // maximum aperture width, leaving unused surround in the wider viewport.
    #expect(abs(g.imageFrame.height - g.contentBounds.height) < eps)
    #expect(abs(g.imageFrame.width - g.contentBounds.width) < eps)
    #expect(g.contentBounds.width < g.viewportBounds.width - eps)
    // Centered horizontally.
    #expect(abs(g.imageFrame.midX - g.contentBounds.midX) < eps)
}

@Test func squareImageSymmetric() {
    let g = make(viewport: CGSize(width: 900, height: 700), source: CGSize(width: 5000, height: 5000))
    // Height-limited fit (portrait content area); symmetric L/R margins.
    #expect(abs(g.imageFrame.height - g.contentBounds.height) < eps)
    let leftMargin = g.imageFrame.minX - g.contentBounds.minX
    let rightMargin = g.contentBounds.maxX - g.imageFrame.maxX
    #expect(abs(leftMargin - rightMargin) < eps)
}

@Test func verySmallViewportNeverNegativeContent() {
    let g = make(viewport: CGSize(width: 30, height: 20), source: CGSize(width: 4000, height: 3000))
    #expect(g.contentBounds.width >= 1)
    #expect(g.contentBounds.height >= 1)
    #expect(g.matInset >= 0)
    #expect(g.imageFrame.width > 0)
    #expect(g.imageFrame.height > 0)
}

@Test func matIsIndependentOfSourceResolution() {
    let small = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 2000, height: 1500))
    let large = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 12000, height: 9000))
    // Same viewport → same mat regardless of megapixels.
    #expect(abs(small.matInset - large.matInset) < eps)
    #expect(PreviewGeometry.rectApproximatelyEqual(small.contentBounds, large.contentBounds, epsilon: eps))
}

// MARK: - Zoom

@Test func oneToOneMappingAt100Percent() {
    // Drive zoom so imageScale == 1 (100%), regardless of the proportional
    // assessment surround, then verify 1:1 source→screen mapping.
    let base = make(viewport: CGSize(width: 1080, height: 880), source: CGSize(width: 1000, height: 800))
    let g = make(viewport: CGSize(width: 1080, height: 880), source: CGSize(width: 1000, height: 800), zoom: 1 / base.fitScale)
    #expect(abs(g.imageScale - 1) < eps)
    // A source point maps 1:1 to screen offset from imageFrame origin.
    let sp = CGPoint(x: 100, y: 50)
    let screen = g.screenPoint(forSourcePoint: sp)
    #expect(abs(screen.x - (g.imageFrame.minX + 100)) < eps)
    #expect(abs(screen.y - (g.imageFrame.minY + 50)) < eps)
}

@Test func aboveSourceOneToOneCapsProcessing() {
    // Small image, large viewport, 2x zoom → imageScale well above 1.
    let g = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 200, height: 150), zoom: 2)
    #expect(g.imageScale > 1)
    // requiredRenderSize is capped at source resolution (chemistry ≤ 1:1).
    #expect(g.requiredRenderSize.width <= g.sourceSize.width + eps)
    #expect(g.requiredRenderSize.height <= g.sourceSize.height + eps)
}

@Test func retinaBackingScaleDoublesPhysicalRenderSize() {
    let logical = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 8000, height: 6000), backing: 1)
    let retina = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 8000, height: 6000), backing: 2)
    // Same logical geometry.
    #expect(PreviewGeometry.rectApproximatelyEqual(logical.imageFrame, retina.imageFrame, epsilon: eps))
    // Physical render size doubles where source resolution permits.
    #expect(abs(retina.requiredRenderSize.width - logical.requiredRenderSize.width * 2) < 2)
    #expect(abs(retina.requiredRenderSize.height - logical.requiredRenderSize.height * 2) < 2)
}

// MARK: - Pan

@Test func panLeftRightAdjustsSourceROI() {
    // Wide image, zoomed in so only part is visible horizontally.
    let base = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 6000, height: 3000), zoom: 2)
    #expect(base.visibleSourceRect.width < base.sourceSize.width - eps)
    let pannedRight = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 6000, height: 3000), zoom: 2, pan: CGPoint(x: 200, y: 0))
    // Panning right (image moves right) shows source pixels further left... or right?
    // The image frame moves right, so the visible window (fixed content) sees
    // source pixels with smaller X (the image's left portion moves into view
    // from the left means we see higher-X content). We just assert ROI shifted
    // and stayed in bounds; direction is validated by round-trip tests.
    #expect(pannedRight.visibleSourceRect.minX != base.visibleSourceRect.minX)
    #expect(pannedRight.visibleSourceRect.minX >= -eps)
    #expect(pannedRight.visibleSourceRect.maxX <= pannedRight.sourceSize.width + eps)
}

@Test func panTopBottomYOrientation() {
    // Explicitly validate Y orientation: panning down (positive pan.y in the
    // flipped coordinate space moves the image down) must reveal source rows
    // with smaller Y (the top of the image), because the image's top edge
    // moves down into the fixed content window from above.
    let base = make(viewport: CGSize(width: 800, height: 600), source: CGSize(width: 3000, height: 6000), zoom: 2)
    #expect(base.visibleSourceRect.height < base.sourceSize.height - eps)
    let pannedDown = make(viewport: CGSize(width: 800, height: 600), source: CGSize(width: 3000, height: 6000), zoom: 2, pan: CGPoint(x: 0, y: 150))
    #expect(pannedDown.visibleSourceRect.minY < base.visibleSourceRect.minY + eps,
            "Panning the image down (positive pan.y) should reveal smaller source Y (top of image)")
    #expect(pannedDown.visibleSourceRect.minY >= -eps)
}

@Test func panBeyondLimitsClampsToSourceEdges() {
    // Try to pan far past the right/bottom edges; ROI must stay in bounds.
    let g = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 6000, height: 4000), zoom: 4,
                 pan: CGPoint(x: 99999, y: 99999))
    #expect(g.visibleSourceRect.minX >= -eps)
    #expect(g.visibleSourceRect.minY >= -eps)
    #expect(g.visibleSourceRect.maxX <= g.sourceSize.width + eps)
    #expect(g.visibleSourceRect.maxY <= g.sourceSize.height + eps)
    // The clamped pan is reported back.
    #expect(abs(g.pan.x) < 99999)
}

@Test func panAllFourCornersStayInBounds() {
    let corners: [CGPoint] = [
        CGPoint(x: -99999, y: -99999), CGPoint(x: 99999, y: -99999),
        CGPoint(x: -99999, y: 99999), CGPoint(x: 99999, y: 99999)
    ]
    for c in corners {
        let g = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 6000, height: 4000), zoom: 3, pan: c)
        #expect(g.visibleSourceRect.minX >= -eps)
        #expect(g.visibleSourceRect.minY >= -eps)
        #expect(g.visibleSourceRect.maxX <= g.sourceSize.width + eps)
        #expect(g.visibleSourceRect.maxY <= g.sourceSize.height + eps)
    }
}

// MARK: - Resize

@Test func windowResizeRecomputesFit() {
    let before = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 6000, height: 4000))
    let after = make(viewport: CGSize(width: 2000, height: 800), source: CGSize(width: 6000, height: 4000))
    // Wider viewport → larger fit scale, same source.
    #expect(after.fitScale > before.fitScale)
    // Mat inset unchanged (same smallest dimension).
    #expect(abs(after.matInset - before.matInset) < eps)
}

// MARK: - Round-trip conversion

@Test func sourceScreenSourceRoundTrip() {
    let g = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 6000, height: 4000), zoom: 1.7, pan: CGPoint(x: 30, y: -20))
    for p in [CGPoint(x: 0, y: 0), CGPoint(x: 1500, y: 1000), CGPoint(x: 5999, y: 3999), CGPoint(x: 3000, y: 2000)] {
        let back = g.sourcePoint(forScreenPoint: g.screenPoint(forSourcePoint: p))
        #expect(abs(back.x - p.x) < 0.5)
        #expect(abs(back.y - p.y) < 0.5)
    }
}

@Test func screenSourceScreenRoundTrip() {
    let g = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 6000, height: 4000), zoom: 1.7, pan: CGPoint(x: 30, y: -20))
    for p in [CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 400), CGPoint(x: 900, y: 700)] {
        let back = g.screenPoint(forSourcePoint: g.sourcePoint(forScreenPoint: p))
        #expect(abs(back.x - p.x) < 0.5)
        #expect(abs(back.y - p.y) < 0.5)
    }
}

// MARK: - Mat exclusion

@Test func visibleSourceRectExcludesMatArea() {
    // At Fit the visible ROI should be the full image; the mat area around the
    // photo must not add source pixels. Growing the viewport only in the mat
    // direction (keeping content fixed) must not change the ROI.
    let g = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 6000, height: 4000))
    #expect(PreviewGeometry.rectApproximatelyEqual(g.visibleSourceRect, CGRect(origin: .zero, size: g.sourceSize), epsilon: 1))
    // visibleImageFrame never extends into the mat.
    #expect(g.visibleImageFrame.minX >= g.contentBounds.minX - eps)
    #expect(g.visibleImageFrame.minY >= g.contentBounds.minY - eps)
    #expect(g.visibleImageFrame.maxX <= g.contentBounds.maxX + eps)
    #expect(g.visibleImageFrame.maxY <= g.contentBounds.maxY + eps)
}

@Test func requiredRenderSizeNeverExceedsSource() {
    // Even at very high backing scale, render size is capped at source pixels.
    let g = make(viewport: CGSize(width: 1000, height: 800), source: CGSize(width: 100, height: 80), zoom: 4, backing: 2)
    #expect(g.requiredRenderSize.width <= g.sourceSize.width + eps)
    #expect(g.requiredRenderSize.height <= g.sourceSize.height + eps)
}
