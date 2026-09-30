#if os(macOS)
import CoreGraphics
import Foundation

/// Canonical preview geometry shared by the AppKit canvas, the AppViewModel
/// render scheduler, and Metal tile presentation. One authoritative object —
/// no component may independently derive viewport bounds, mat, fit, pan, or
/// visible source ROI from raw inputs.
///
/// All rect/point/size values use the view's flipped logical-point space
/// (top-left origin, Y increases downward), matching `ZoomableImageCanvas`
/// (isFlipped = true) and the source-rect convention expected by
/// `ImageCodec.loadRAWLinearSRGBRegion` (top-left image pixels).
public struct PreviewGeometry: Equatable, Sendable {

    /// Screen-space drawable bounds of the preview view (logical points).
    public let viewportBounds: CGRect

    /// Image aperture in screen space. Rendered photo pixels are clipped here.
    /// The aperture is permanently inset from the viewport so the assessment
    /// surround remains visible even when the photograph is zoomed beyond it.
    public let contentBounds: CGRect

    /// White mat-board rectangle surrounding the image aperture. The gray
    /// assessment background remains visible outside this rectangle.
    public let matBounds: CGRect

    /// Full source image dimensions in original pixels.
    public let sourceSize: CGSize

    /// Scale that aspect-fits the complete source image inside contentBounds.
    public let fitScale: CGFloat

    /// Zoom multiplier relative to Fit (1 = Fit). UI-facing value.
    public let zoom: CGFloat

    /// Effective source-pixel → logical-point scale. This is the authoritative
    /// presentation scale used to compute imageFrame and source ROI.
    public let imageScale: CGFloat

    /// Complete photograph rectangle in viewport coordinates (includes pan).
    public let imageFrame: CGRect

    /// Portion of imageFrame that intersects contentBounds. The renderer
    /// never processes pixels outside this frame (the mat area contributes
    /// no source pixels).
    public let visibleImageFrame: CGRect

    /// Visible rectangle expressed in original source-image pixels
    /// (top-left origin). Never extends past the source.
    public let visibleSourceRect: CGRect

    /// Physical backing scale of the display/view (2.0 on Retina).
    public let backingScale: CGFloat

    /// Physical-pixel dimensions required to represent the visible ROI on
    /// screen. Capped at source resolution so chemistry never exceeds 1:1.
    public let requiredRenderSize: CGSize

    /// Effective mat inset in logical screen points (after small-window clamp).
    public let matInset: CGFloat

    /// The clamped pan offset used to place imageFrame. The canvas may adopt
    /// this back into its gesture state to keep the pan in sync with limits.
    public let pan: CGPoint

    public init(
        viewportBounds: CGRect,
        contentBounds: CGRect,
        matBounds: CGRect,
        sourceSize: CGSize,
        fitScale: CGFloat,
        zoom: CGFloat,
        imageScale: CGFloat,
        imageFrame: CGRect,
        visibleImageFrame: CGRect,
        visibleSourceRect: CGRect,
        backingScale: CGFloat,
        requiredRenderSize: CGSize,
        matInset: CGFloat,
        pan: CGPoint
    ) {
        self.viewportBounds = viewportBounds
        self.contentBounds = contentBounds
        self.matBounds = matBounds
        self.sourceSize = sourceSize
        self.fitScale = fitScale
        self.zoom = zoom
        self.imageScale = imageScale
        self.imageFrame = imageFrame
        self.visibleImageFrame = visibleImageFrame
        self.visibleSourceRect = visibleSourceRect
        self.backingScale = backingScale
        self.requiredRenderSize = requiredRenderSize
        self.matInset = matInset
        self.pan = pan
    }

    // MARK: - Coordinate conversion helpers

    /// Source-pixel point → screen (viewport) point.
    public func screenPoint(forSourcePoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + point.x * imageScale,
            y: imageFrame.minY + point.y * imageScale
        )
    }

    /// Screen (viewport) point → source-pixel point.
    public func sourcePoint(forScreenPoint point: CGPoint) -> CGPoint {
        guard imageScale > 0 else { return .zero }
        return CGPoint(
            x: (point.x - imageFrame.minX) / imageScale,
            y: (point.y - imageFrame.minY) / imageScale
        )
    }

    /// Source-pixel rect → screen (viewport) rect.
    public func screenRect(forSourceRect rect: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + rect.minX * imageScale,
            y: imageFrame.minY + rect.minY * imageScale,
            width: rect.width * imageScale,
            height: rect.height * imageScale
        )
    }

    /// Screen (viewport) rect → source-pixel rect (clamped to source bounds).
    public func sourceRect(forScreenRect rect: CGRect) -> CGRect {
        guard imageScale > 0 else { return .zero }
        let r = CGRect(
            x: (rect.minX - imageFrame.minX) / imageScale,
            y: (rect.minY - imageFrame.minY) / imageScale,
            width: rect.width / imageScale,
            height: rect.height / imageScale
        )
        return r.intersection(CGRect(origin: .zero, size: sourceSize))
    }

    // MARK: - Idempotence / epsilon comparison

    /// Fuzzy equality for geometry comparisons before publishing state.
    /// Prevents layout → callback → state → layout feedback loops.
    public static func approximatelyEqual(_ lhs: PreviewGeometry, _ rhs: PreviewGeometry, epsilon: CGFloat = 0.25) -> Bool {
        rectApproximatelyEqual(lhs.viewportBounds, rhs.viewportBounds, epsilon: epsilon) &&
        rectApproximatelyEqual(lhs.contentBounds, rhs.contentBounds, epsilon: epsilon) &&
        rectApproximatelyEqual(lhs.matBounds, rhs.matBounds, epsilon: epsilon) &&
        rectApproximatelyEqual(lhs.imageFrame, rhs.imageFrame, epsilon: epsilon) &&
        rectApproximatelyEqual(lhs.visibleImageFrame, rhs.visibleImageFrame, epsilon: epsilon) &&
        rectApproximatelyEqual(lhs.visibleSourceRect, rhs.visibleSourceRect, epsilon: epsilon) &&
        abs(lhs.fitScale - rhs.fitScale) < epsilon &&
        abs(lhs.zoom - rhs.zoom) < epsilon &&
        abs(lhs.imageScale - rhs.imageScale) < epsilon &&
        abs(lhs.backingScale - rhs.backingScale) < epsilon &&
        abs(lhs.matInset - rhs.matInset) < epsilon &&
        abs(lhs.pan.x - rhs.pan.x) < epsilon &&
        abs(lhs.pan.y - rhs.pan.y) < epsilon
    }

    public static func rectApproximatelyEqual(_ a: CGRect, _ b: CGRect, epsilon: CGFloat = 0.25) -> Bool {
        abs(a.minX - b.minX) < epsilon &&
        abs(a.minY - b.minY) < epsilon &&
        abs(a.width - b.width) < epsilon &&
        abs(a.height - b.height) < epsilon
    }
}

// MARK: - Calculator

public enum PreviewGeometryCalculator {

    /// ISO-style assessment surround. The full reserved surround is 12.5% of
    /// the shorter viewport dimension. This is deliberately proportional to
    /// the viewport, not a hard-coded point count and not source resolution.
    public static let surroundFraction: CGFloat = 0.125

    /// Half of the reserved surround is gray assessment background and half is
    /// the white mat board when there is enough room. When the displayed photo
    /// becomes smaller than the viewport, only the white part is allowed to
    /// shrink with it; the gray assessment surround remains visible.
    public static let matShareOfSurround: CGFloat = 0.5

    public static func calculate(
        viewportBounds: CGRect,
        sourceSize: CGSize,
        zoom: CGFloat,
        pan: CGPoint,
        backingScale: CGFloat,
        matInset: CGFloat
    ) -> PreviewGeometry {
        let viewportMin = max(1, min(viewportBounds.width, viewportBounds.height))

        // The old API's matInset argument is intentionally ignored. The mat is
        // now derived from viewport geometry, matching the assessment-view
        // semantics. Keeping the argument avoids a broad call-site migration.
        _ = matInset

        // Reserve a proportional assessment surround. This defines the maximum
        // image aperture, not the aperture at every zoom level. When the
        // displayed photograph is smaller than this maximum, the aperture (and
        // therefore the white mat board) follows the displayed photograph.
        // Once the photograph grows beyond it, the aperture clamps here so the
        // white mat and gray assessment background remain permanently visible.
        let reservedSurround = min(viewportMin * surroundFraction, max(0, (viewportMin - 1) * 0.5))
        let maximumAperture = CGRect(
            x: viewportBounds.minX + reservedSurround,
            y: viewportBounds.minY + reservedSurround,
            width: max(1, viewportBounds.width - 2 * reservedSurround),
            height: max(1, viewportBounds.height - 2 * reservedSurround)
        )

        // Fit is defined against the maximum aperture. This keeps the existing
        // Fit/zoom semantics stable: zoom == 1 still means the largest complete
        // photograph that fits inside the assessment surround.
        let fitScale: CGFloat
        if sourceSize.width > 0, sourceSize.height > 0 {
            fitScale = min(maximumAperture.width / sourceSize.width, maximumAperture.height / sourceSize.height)
        } else {
            fitScale = 1
        }
        let imageScale = fitScale * max(zoom, 0.01)
        let displayWidth = sourceSize.width * imageScale
        let displayHeight = sourceSize.height * imageScale

        // The aperture is image-owned while the displayed photo fits. It grows
        // and shrinks with the photo. Per axis, it stops growing at the maximum
        // aperture. From that point onward the photo pans/zooms behind the
        // fixed aperture instead of covering the mat/surround.
        let apertureWidth = min(maximumAperture.width, max(1, displayWidth))
        let apertureHeight = min(maximumAperture.height, max(1, displayHeight))
        let contentBounds = CGRect(
            x: viewportBounds.midX - apertureWidth * 0.5,
            y: viewportBounds.midY - apertureHeight * 0.5,
            width: apertureWidth,
            height: apertureHeight
        )

        let clampedPan = CGPoint(
            x: constrainedAxisPan(pan: pan.x, imageExtent: displayWidth, containerExtent: apertureWidth),
            y: constrainedAxisPan(pan: pan.y, imageExtent: displayHeight, containerExtent: apertureHeight)
        )
        let imageFrame = CGRect(
            x: contentBounds.midX + clampedPan.x - displayWidth * 0.5,
            y: contentBounds.midY + clampedPan.y - displayHeight * 0.5,
            width: displayWidth,
            height: displayHeight
        )

        // The mat thickness is derived from the viewport assessment surround,
        // never from a hard-coded point value. Its OUTER SIZE shrinks when the
        // image/aperture shrinks; when the aperture reaches its maximum size,
        // the mat stops growing and the remaining viewport stays gray.
        let matThickness = max(1, reservedSurround * matShareOfSurround)
        let matBounds = contentBounds
            .insetBy(dx: -matThickness, dy: -matThickness)
            .intersection(viewportBounds)

        let visibleImageFrame = imageFrame.intersection(contentBounds)
        let sourceRect = rectToSource(
            screenRect: visibleImageFrame,
            imageFrame: imageFrame,
            imageScale: imageScale,
            sourceSize: sourceSize
        )

        let requiredWidth = min((visibleImageFrame.width * backingScale).rounded(.up), sourceSize.width)
        let requiredHeight = min((visibleImageFrame.height * backingScale).rounded(.up), sourceSize.height)
        let requiredRenderSize = CGSize(width: max(1, requiredWidth), height: max(1, requiredHeight))

        return PreviewGeometry(
            viewportBounds: viewportBounds,
            contentBounds: contentBounds,
            matBounds: matBounds,
            sourceSize: sourceSize,
            fitScale: fitScale,
            zoom: zoom,
            imageScale: imageScale,
            imageFrame: imageFrame,
            visibleImageFrame: visibleImageFrame,
            visibleSourceRect: sourceRect,
            backingScale: backingScale,
            requiredRenderSize: requiredRenderSize,
            matInset: matThickness,
            pan: clampedPan
        )
    }

    static func constrainedAxisPan(pan: CGFloat, imageExtent: CGFloat, containerExtent: CGFloat) -> CGFloat {
        if imageExtent <= containerExtent { return 0 }
        let maxPan = (imageExtent - containerExtent) * 0.5
        return min(max(pan, -maxPan), maxPan)
    }

    private static func rectToSource(
        screenRect: CGRect,
        imageFrame: CGRect,
        imageScale: CGFloat,
        sourceSize: CGSize
    ) -> CGRect {
        guard imageScale > 0 else { return .zero }
        let r = CGRect(
            x: (screenRect.minX - imageFrame.minX) / imageScale,
            y: (screenRect.minY - imageFrame.minY) / imageScale,
            width: screenRect.width / imageScale,
            height: screenRect.height / imageScale
        )
        return r.intersection(CGRect(origin: .zero, size: sourceSize))
    }
}

// MARK: - Progressive preview quality

/// Quality tiers for progressive viewport rendering. The scheduler runs
/// passes in increasing resolution order, each targeting a fraction of the
/// final required render size.
public enum PreviewQuality: Sendable, CaseIterable, Comparable {
    case interactiveQuarter
    case interactiveHalf
    case final

    public static func < (lhs: PreviewQuality, rhs: PreviewQuality) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .interactiveQuarter: return 0
        case .interactiveHalf: return 1
        case .final: return 2
        }
    }

    /// Scale factor applied to the final required render size for this pass.
    public var resolutionScale: Double {
        switch self {
        case .interactiveQuarter: return 0.25
        case .interactiveHalf: return 0.5
        case .final: return 1.0
        }
    }
}

// MARK: - Render request

/// A snapshot of everything needed to render one progressive pass of the
/// visible viewport ROI. Carries a generation identifier so stale work can
/// be discarded before or between passes.
public struct PreviewRenderRequest: Sendable {
    /// Monotonic generation identifier. Incremented whenever a change
    /// invalidates the requested viewport (pan, zoom, resize, source change,
    /// adjustment/film/print change). Stale generations must not overwrite
    /// newer results.
    public let generation: UInt64

    /// The source-image rectangle to render (top-left origin, source pixels).
    /// This is the *visible* ROI — no processing halo is included.
    public let sourceRect: CGRect

    /// Target output pixel dimensions for this pass.
    public let outputSize: CGSize

    /// Chemistry scale. Always ≤ 1.0 so the pipeline never runs above
    /// original source resolution; presentation handles enlargement.
    public let processingScale: Double

    /// Progressive quality tier.
    public let quality: PreviewQuality

    /// The canonical geometry at the time of the request.
    public let geometry: PreviewGeometry

    public init(
        generation: UInt64,
        sourceRect: CGRect,
        outputSize: CGSize,
        processingScale: Double,
        quality: PreviewQuality,
        geometry: PreviewGeometry
    ) {
        self.generation = generation
        self.sourceRect = sourceRect
        self.outputSize = outputSize
        self.processingScale = processingScale
        self.quality = quality
        self.geometry = geometry
    }
}
#endif
