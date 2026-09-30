#if os(macOS)
import AppKit
import Combine
import CoreGraphics
import Foundation
import Metal
import SpektrafilmCore
import SpektrafilmPreviewGeometry

/// Read-only render state the viewport scheduler needs.
@MainActor
protocol PreviewRenderStateReading: AnyObject {
    var isRendering: Bool { get }
    var lastAutoExposureEV: Double { get }
}

/// Narrow view of the profile-preview service for suspending/resuming
/// background thumbnail work around an interactive viewport render.
@MainActor
protocol BackgroundPreviewCoordinating: AnyObject {
    var backgroundPreviewsSuspended: Bool { get }
    func suspendBackgroundPreviews()
    func resumeBackgroundPreviewsIfNeeded(parameters: RenderParameters)
}

/// Seam over ROI decode/encode, which are MainActor-bound.
nonisolated protocol ViewportDecoding: Sendable {
    func loadRegion(url: URL, rect: CGRect, rawAdjustments: RAWAdjustments, isRAW: Bool, outputScale: Double) async throws -> LinearRGBImage
    func makeNSImage(_ image: LinearRGBImage, encodeSRGB: Bool) async -> NSImage?
}

nonisolated struct LiveViewportDecoder: ViewportDecoding {
    func loadRegion(url: URL, rect: CGRect, rawAdjustments: RAWAdjustments, isRAW: Bool, outputScale: Double) async throws -> LinearRGBImage {
        try await ImageCodec.loadSourceLinearSRGBRegion(url: url, rect: rect, rawAdjustments: rawAdjustments, isRAW: isRAW, outputScale: outputScale)
    }

    func makeNSImage(_ image: LinearRGBImage, encodeSRGB: Bool) async -> NSImage? {
        await ImageCodec.makeNSImage(image, encodeSRGB: encodeSRGB)
    }
}

/// Seam over the CPU fallback chemistry render for a ROI.
nonisolated protocol ViewportImageRendering: Sendable {
    func render(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters,
        resources: PipelineResources?,
        sourceLongSideOverride: Int,
        autoExposureEVOverride: Double,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> LinearRGBImage
}

nonisolated struct LiveViewportImageRenderer: ViewportImageRendering {
    func render(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters,
        resources: PipelineResources?,
        sourceLongSideOverride: Int,
        autoExposureEVOverride: Double,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> LinearRGBImage {
        try MetalAccelerator.shared.withWorkPriority(.interactive) {
            try SpektrafilmPipeline.render(
                input: input,
                film: film,
                print: print,
                parameters: parameters,
                resources: resources,
                isCancelled: isCancelled,
                sourceLongSideOverride: sourceLongSideOverride,
                autoExposureEVOverride: autoExposureEVOverride
            ).image
        }
    }
}

/// Owns the viewport ROI / 1:1 detail-tile pipeline: request coalescing,
/// progressive passes, fixed-tile caching and background-preview suspension.
///
/// Tiles are tagged with `rendered`: chemistry tiles ("after") and unedited
/// source tiles ("before"). Click/hold compare requests the `before` set; the
/// before/after slider requests both sets so each side is sharp.
@MainActor
final class ViewportService: ObservableObject {
    @Published private(set) var detailPreviewTiles: [PreviewDetailTile] = []

    private(set) var lastViewportGeometry: PreviewGeometry?
    private(set) var lastViewportRendered: Bool = true
    private(set) var comparisonSliderActive = false

    private var detailRenderTask: Task<Void, Never>?
    private var detailGeneration: UInt = 0
    private var detailCacheEpoch: UInt = 0
    private var detailTileCache: [DetailTileKey: PreviewDetailTile] = [:]
    private var detailTileLRU: [DetailTileKey] = []
    /// Low-resolution progressive tiles shown while the full 1:1 tile is still refining.
    private var detailDraftTileCache: [DetailTileKey: PreviewDetailTile] = [:]
    private var detailDraftTileLRU: [DetailTileKey] = []
    private let detailTileSize = 640
    private let detailTileHalo = 32
    private let detailTileCacheLimit = 32
    private let detailDraftTileCacheLimit = 20

    /// Coalescing state for viewport render scheduling. Newest request wins;
    /// intermediate states are discarded rather than rendered one-per-event.
    private var pendingViewportGeometry: PreviewGeometry?
    private var pendingViewportRendered: Bool = true
    private var pendingViewportParameters: RenderParameters?
    private var viewportSchedulerTask: Task<Void, Never>?
    /// Interactive viewport render coalescing interval (~30 Hz).
    private let viewportCoalesceMilliseconds = 33

    /// Progressive viewport tiles, one per active render flag (before/after).
    private var viewportPreviewTiles: [PreviewDetailTile] = []
    /// Visible source rect and render flags for the in-flight generation.
    private var currentVisibleRect: CGRect?
    private var currentRenderFlags: [Bool] = [true]

    /// Bumped only when the decoded source changes (new image or RAW state).
    /// The unedited "before" tiles are keyed by this, not the chemistry epoch,
    /// so parameter/film changes do not invalidate them.
    private var sourceCacheEpoch: UInt = 0
    /// Final-scale viewport tile per render flag for the current viewport.
    private var viewportTileCache: [Bool: CachedViewportTile] = [:]
    /// Flags still needing a render for the pending request (cache misses).
    private var pendingViewportMissingFlags: [Bool] = []

    private struct ViewportKey: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let scale: Double
        let epoch: UInt
    }

    private struct CachedViewportTile {
        let key: ViewportKey
        let tile: PreviewDetailTile
    }

    private let profiles: ProfileProviding
    private let images: ImageSourceProviding
    private let renderState: PreviewRenderStateReading
    private let previews: BackgroundPreviewCoordinating
    private let decoder: ViewportDecoding
    private let imageRenderer: ViewportImageRendering

    init(profiles: ProfileProviding,
         images: ImageSourceProviding,
         renderState: PreviewRenderStateReading,
         previews: BackgroundPreviewCoordinating,
         decoder: ViewportDecoding = LiveViewportDecoder(),
         imageRenderer: ViewportImageRendering = LiveViewportImageRenderer()) {
        self.profiles = profiles
        self.images = images
        self.renderState = renderState
        self.previews = previews
        self.decoder = decoder
        self.imageRenderer = imageRenderer
    }

    func requestViewportPreview(_ geometry: PreviewGeometry, rendered: Bool, parameters: RenderParameters) {
        lastViewportGeometry = geometry
        lastViewportRendered = rendered
        guard images.sourceURL != nil, images.sourcePixelSize.width > 0, images.sourcePixelSize.height > 0 else { return }
        guard !parameters.io.crop, abs(parameters.io.upscale - 1) < 1e-12 else {
            cancelPendingViewportWork()
            clearPublishedTiles()
            return
        }

        // Below 20% the normal full-frame navigation proxy already has enough
        // pixels; don't spend chemistry work on an ROI the user cannot resolve.
        guard geometry.imageScale >= 0.20 else {
            cancelPendingViewportWork()
            clearPublishedTiles()
            resumeBackgroundPreviewsIfNeeded(parameters: parameters)
            return
        }

        guard geometry.visibleSourceRect.width >= 1, geometry.visibleSourceRect.height >= 1 else { return }

        // Serve cached tiles synchronously so compare/slider toggles that did not
        // move the viewport swap instantly without re-rendering.
        let bounds = CGRect(origin: .zero, size: images.sourcePixelSize)
        let visible = geometry.visibleSourceRect.intersection(bounds).integral
        let requiredFlags: [Bool] = comparisonSliderActive ? [true, false] : [rendered]
        var cachedTiles: [PreviewDetailTile] = []
        var missingFlags: [Bool] = []
        for flag in requiredFlags {
            if let entry = viewportTileCache[flag], entry.key == viewportCacheKey(for: geometry, rendered: flag) {
                cachedTiles.append(entry.tile)
            } else {
                viewportTileCache[flag] = nil
                missingFlags.append(flag)
            }
        }
        if !cachedTiles.isEmpty {
            currentVisibleRect = visible
            currentRenderFlags = requiredFlags
            for tile in cachedTiles { setViewportPreviewTile(tile) }
            publishCurrentTiles()
        }
        guard !missingFlags.isEmpty else { return }

        // Coalesce: store the newest request and let the scheduler consume it.
        pendingViewportGeometry = geometry
        pendingViewportRendered = rendered
        pendingViewportParameters = parameters
        pendingViewportMissingFlags = missingFlags
        scheduleViewportRender()
    }

    /// Click/hold compare toggled. Serves the matching tile set from cache or
    /// re-renders it, clearing the stale set immediately so the swap is visible.
    func compareModeDidChange(showOriginal: Bool, parameters: RenderParameters) {
        let rendered = !showOriginal
        guard rendered != lastViewportRendered, let geometry = lastViewportGeometry else { return }
        cancelPendingViewportWork()
        clearPublishedTiles()
        requestViewportPreview(geometry, rendered: rendered, parameters: parameters)
    }

    /// Before/after slider toggled. Requests both tile sets (sharp before on
    /// the left, sharp after on the right), reusing whichever is cached.
    func setComparisonSliderActive(_ active: Bool, parameters: RenderParameters) {
        guard active != comparisonSliderActive else { return }
        comparisonSliderActive = active
        guard let geometry = lastViewportGeometry else { return }
        cancelPendingViewportWork()
        clearPublishedTiles()
        requestViewportPreview(geometry, rendered: lastViewportRendered, parameters: parameters)
    }

    /// Chemistry/parameters changed: the "after" set is invalidated, but the
    /// unedited "before" set is keyed by source state and survives.
    func invalidateDetailTiles() {
        cancelDetailWork(clearSource: false)
        clearPublishedTiles()
    }

    /// Source changed (new image or RAW state): both tile sets are invalidated.
    /// Keeps the last geometry so the ROI can be re-requested.
    func sourceDidChange() {
        cancelDetailWork(clearSource: true)
        clearPublishedTiles()
    }

    /// Invalidates tiles and forgets the last geometry for a new source/RAW state.
    func resetForSourceChange() {
        cancelDetailWork(clearSource: true)
        clearPublishedTiles()
        lastViewportGeometry = nil
    }

    // MARK: - Viewport tile cache

    private func finalScale(for geometry: PreviewGeometry) -> Double {
        let desired = min(max(Double(geometry.imageScale) * Double(geometry.backingScale), 0.01), 1.0)
        return desired <= 0.25 ? 0.25 : desired <= 0.5 ? 0.5 : 1.0
    }

    private func viewportCacheKey(for geometry: PreviewGeometry, rendered: Bool) -> ViewportKey {
        let bounds = CGRect(origin: .zero, size: images.sourcePixelSize)
        let visible = geometry.visibleSourceRect.intersection(bounds).integral
        return ViewportKey(
            x: Int(visible.minX), y: Int(visible.minY),
            width: Int(visible.width), height: Int(visible.height),
            scale: finalScale(for: geometry),
            epoch: rendered ? detailCacheEpoch : sourceCacheEpoch
        )
    }

    // MARK: - Scheduling

    private func scheduleViewportRender() {
        guard viewportSchedulerTask == nil else { return }
        viewportSchedulerTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(self?.viewportCoalesceMilliseconds ?? 33)) } catch { return }
            guard let self else { return }
            self.viewportSchedulerTask = nil
            guard let geometry = self.pendingViewportGeometry else { return }
            let rendered = self.pendingViewportRendered
            let parameters = self.pendingViewportParameters ?? RenderParameters()
            let missingFlags = self.pendingViewportMissingFlags
            self.pendingViewportGeometry = nil
            self.pendingViewportParameters = nil
            self.pendingViewportMissingFlags = []
            self.startViewportRender(geometry: geometry, rendered: rendered, parameters: parameters, renderFlags: missingFlags)
        }
    }

    private func startViewportRender(geometry: PreviewGeometry, rendered: Bool, parameters: RenderParameters, renderFlags: [Bool]) {
        guard let sourceURL = images.sourceURL else { return }
        previews.suspendBackgroundPreviews()
        if renderState.isRendering { return }
        let bounds = CGRect(origin: .zero, size: images.sourcePixelSize)
        let visible = geometry.visibleSourceRect.intersection(bounds).integral
        guard visible.width >= 1, visible.height >= 1 else { return }

        detailRenderTask?.cancel(); detailGeneration &+= 1
        let generation = detailGeneration
        // Publishing covers every required flag; only the cache misses render.
        let requiredFlags: [Bool] = comparisonSliderActive ? [true, false] : [rendered]
        currentVisibleRect = visible
        currentRenderFlags = requiredFlags
        let cacheKeys: [Bool: ViewportKey] = Dictionary(uniqueKeysWithValues: renderFlags.map { ($0, viewportCacheKey(for: geometry, rendered: $0)) })
        let film = profiles.selectedFilm, paper = profiles.selectedPrint
        var p = parameters; p.settings.previewMode = true
        let resources = profiles.pipelineResources
        let fullLongSide = Int(max(images.sourcePixelSize.width, images.sourcePixelSize.height))
        let autoEV = renderState.lastAutoExposureEV
        let sourceBounds = bounds
        let raw = images.rawAdjustments, rawSource = images.isRAWSource
        let revision = UInt64(images.sourceImageRevision)
        let sourceWidth = Int(images.sourcePixelSize.width)
        let refineEnabled = parameters.debug.enableFixedTileRefinement

        // Chemistry never runs above original source resolution; presentation
        // (Metal / CAMetalLayer) magnifies the result. On a Retina display the
        // physical scale can exceed the logical image scale, so a 50% zoom on
        // a 2× screen still decodes at 1:1.
        let finalScale = finalScale(for: geometry)
        var passes: [Double] = []
        for candidate in [0.25, 0.5, finalScale] where candidate <= finalScale + 1e-9 {
            if passes.last.map({ abs($0-candidate) > 1e-9 }) ?? true { passes.append(candidate) }
        }
        // A halo is retained around the viewport so spatial operators do not see
        // the crop boundary. At coarse scales the same source-space halo becomes
        // fewer processing pixels automatically.
        let halo = CGFloat(max(detailTileHalo, 64))
        let expanded = visible.insetBy(dx: -halo, dy: -halo).intersection(sourceBounds).integral
        let encodeSRGB = !p.io.outputCCTFEncoding
        AppLog.info("preview", "ROI generation=\(generation) flags=\(renderFlags) scale=\(String(format: "%.2f", Double(geometry.imageScale))) backing=\(String(format: "%.1f", Double(geometry.backingScale))) passes=\(passes) rect=\(Int(visible.minX)),\(Int(visible.minY)) \(Int(visible.width))×\(Int(visible.height)) required=\(Int(geometry.requiredRenderSize.width))×\(Int(geometry.requiredRenderSize.height))")

        let decoder = self.decoder
        let imageRenderer = self.imageRenderer
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for (index, passScale) in passes.enumerated() {
                    try Task.checkCancellation()
                    guard let self else { return }
                    // Only the first coarse pass starts immediately. Later passes wait
                    // briefly; pan/zoom generations usually cancel before GPU submission.
                    if index == 1 { try await Task.sleep(for: .milliseconds(55)) }
                    if index == 2 { try await Task.sleep(for: .milliseconds(90)) }
                    try Task.checkCancellation()
                    let started = ContinuousClock.now
                    let input = try await decoder.loadRegion(url: sourceURL, rect: expanded, rawAdjustments: raw, isRAW: rawSource, outputScale: passScale)
                    try Task.checkCancellation()
                    let sx = Double(input.width) / Double(max(Int(expanded.width),1))
                    let sy = Double(input.height) / Double(max(Int(expanded.height),1))
                    let cropX = Int(Double(visible.minX-expanded.minX)*sx)
                    let cropY = Int(Double(visible.minY-expanded.minY)*sy)
                    let cropW = max(1, Int((Double(visible.width)*sx).rounded()))
                    let cropH = max(1, Int((Double(visible.height)*sy).rounded()))
                    let isFinalPass = index == passes.count - 1
                    for flag in renderFlags {
                        try Task.checkCancellation()
                        var produced = false
#if canImport(Metal)
                        if flag, let film {
                            let context = SpektrafilmPipeline.PreviewCacheContext(sourceRevision: revision, x: Int(expanded.minX), y: Int(expanded.minY), width: Int(expanded.width), height: Int(expanded.height), scale: passScale, sourceWidth: sourceWidth)
                            if let result = MetalAccelerator.shared.withWorkPriority(.interactive, {
                                SpektrafilmPipeline.renderPreviewTexture(input: input, film: film, print: paper, parameters: p, resources: resources, sourceLongSideOverride: fullLongSide, autoExposureEVOverride: autoEV, cropX: cropX, cropY: cropY, cropWidth: cropW, cropHeight: cropH, renderScale: passScale, cacheContext: context, isCancelled: { Task.isCancelled })
                            }) {
                                try Task.checkCancellation()
                                await MainActor.run { [weak self] in
                                    guard let self, self.detailGeneration == generation else { return }
                                    let tile = PreviewDetailTile(texture: result.texture, sourceRect: visible, rendered: true)
                                    self.setViewportPreviewTile(tile)
                                    if isFinalPass, let key = cacheKeys[true] {
                                        self.viewportTileCache[true] = CachedViewportTile(key: key, tile: tile)
                                    }
                                    self.publishCurrentTiles()
                                    AppLog.info("preview", "ROI pass \(String(format: "%.2f", passScale))x after ready in \(AppLog.formatElapsed(AppLog.msSince(started)))")
                                }
                                produced = true
                            }
                        }
#endif
                        // CPU/fallback path remains correct on systems where the resident
                        // texture path is unavailable. It still benefits from scale-aware ROI decode.
                        if !produced {
                            let processed: LinearRGBImage
                            if flag, let film {
                                processed = try imageRenderer.render(input: input, film: film, print: paper, parameters: p, resources: resources, sourceLongSideOverride: fullLongSide, autoExposureEVOverride: autoEV, isCancelled: { Task.isCancelled })
                            } else { processed = input }
                            try Task.checkCancellation()
                            let cropped = Self.cropLinearImage(processed, x: cropX, y: cropY, width: cropW, height: cropH)
                            if let image = await decoder.makeNSImage(cropped, encodeSRGB: flag ? encodeSRGB : true) {
                                await MainActor.run { [weak self] in
                                    guard let self, self.detailGeneration == generation else { return }
                                    let tile = PreviewDetailTile(image: image, sourceRect: visible, rendered: flag)
                                    self.setViewportPreviewTile(tile)
                                    if isFinalPass, let key = cacheKeys[flag] {
                                        self.viewportTileCache[flag] = CachedViewportTile(key: key, tile: tile)
                                    }
                                    self.publishCurrentTiles()
                                    AppLog.info("preview", "ROI pass \(String(format: "%.2f", passScale))x \(flag ? "after" : "before") ready in \(AppLog.formatElapsed(AppLog.msSince(started)))")
                                }
                            }
                        }
                    }
                }

                // Idle refinement: only after a final 1:1 viewport exists do we fill
                // reusable fixed tiles. These survive small pans and are no longer on
                // the critical interaction path.
                if finalScale >= 0.999, refineEnabled {
                    try await Task.sleep(for: .milliseconds(220)); try Task.checkCancellation()
                    guard let self else { return }
                    for flag in renderFlags {
                        let keys = await MainActor.run { self.detailKeysCovering(visible, rendered: flag) }
                        let center = CGPoint(x: visible.midX, y: visible.midY)
                        let missing = await MainActor.run { keys.filter { self.detailTileCache[$0] == nil }.sorted { self.detailCoreRect(for: $0).centerDistanceSquared(to: center) < self.detailCoreRect(for: $1).centerDistanceSquared(to: center) } }
                        for key in missing {
                            try Task.checkCancellation()
                            let core = await MainActor.run { self.detailCoreRect(for: key).intersection(sourceBounds) }
                            guard core.width >= 1, core.height >= 1 else { continue }
                            let tileExpanded = core.insetBy(dx: -CGFloat(self.detailTileHalo), dy: -CGFloat(self.detailTileHalo)).intersection(sourceBounds).integral
                            let input = try await decoder.loadRegion(url: sourceURL, rect: tileExpanded, rawAdjustments: raw, isRAW: rawSource, outputScale: 1)
                            try Task.checkCancellation()
                            let cx = Int(core.minX-tileExpanded.minX), cy = Int(core.minY-tileExpanded.minY)
                            var produced = false
#if canImport(Metal)
                            if flag, let film {
                                let ctx = SpektrafilmPipeline.PreviewCacheContext(sourceRevision: revision, x: Int(tileExpanded.minX), y: Int(tileExpanded.minY), width: Int(tileExpanded.width), height: Int(tileExpanded.height), scale: 1, sourceWidth: sourceWidth)
                                if let result = MetalAccelerator.shared.withWorkPriority(.interactive, { SpektrafilmPipeline.renderPreviewTexture(input: input, film: film, print: paper, parameters: p, resources: resources, sourceLongSideOverride: fullLongSide, autoExposureEVOverride: autoEV, cropX: cx, cropY: cy, cropWidth: Int(core.width), cropHeight: Int(core.height), renderScale: 1, cacheContext: ctx, isCancelled: { Task.isCancelled }) }) {
                                    await MainActor.run { [weak self] in
                                        guard let self, self.detailGeneration == generation else { return }
                                        self.insertDetailTile(PreviewDetailTile(texture: result.texture, sourceRect: core, rendered: true), for: key)
                                        self.publishCurrentTiles()
                                    }
                                    produced = true
                                }
                            }
#endif
                            if !produced {
                                let processed = flag && film != nil ? try imageRenderer.render(input: input, film: film!, print: paper, parameters: p, resources: resources, sourceLongSideOverride: fullLongSide, autoExposureEVOverride: autoEV, isCancelled: { Task.isCancelled }) : input
                                let cropped = Self.cropLinearImage(processed, x: cx, y: cy, width: Int(core.width), height: Int(core.height))
                                if let image = await decoder.makeNSImage(cropped, encodeSRGB: flag ? encodeSRGB : true) {
                                    await MainActor.run { [weak self] in
                                        guard let self, self.detailGeneration == generation else { return }
                                        self.insertDetailTile(PreviewDetailTile(image: image, sourceRect: core, rendered: flag), for: key)
                                        self.publishCurrentTiles()
                                    }
                                }
                            }
                        }
                    }
                }
                await MainActor.run { [weak self] in guard let self, self.detailGeneration == generation else { return }; self.detailRenderTask = nil; self.resumeBackgroundPreviewsIfNeeded(parameters: parameters, delayMilliseconds: 900) }
            } catch is CancellationError {
                AppLog.debug("preview", "ROI generation \(generation) cancelled before stale refinement")
            } catch { AppLog.warning("preview", "ROI preview failed: \(error)") }
        }
        detailRenderTask = task
    }

    // MARK: - Tile bookkeeping

    struct DetailTileKey: Hashable {
        let x: Int
        let y: Int
        let rendered: Bool
        let generation: UInt
    }

    private func setViewportPreviewTile(_ tile: PreviewDetailTile) {
        viewportPreviewTiles.removeAll { $0.rendered == tile.rendered }
        viewportPreviewTiles.append(tile)
    }

    private func publishCurrentTiles() {
        guard let visible = currentVisibleRect else {
            if !detailPreviewTiles.isEmpty { detailPreviewTiles = [] }
            return
        }
        var tiles: [PreviewDetailTile] = []
        for flag in currentRenderFlags {
            let keys = detailKeysCovering(visible, rendered: flag)
            tiles.append(contentsOf: keys.compactMap { detailTileCache[$0] ?? detailDraftTileCache[$0] })
        }
        tiles.append(contentsOf: viewportPreviewTiles)
        if !Self.sameTiles(tiles, detailPreviewTiles) {
            detailPreviewTiles = tiles
        }
    }

    private func clearPublishedTiles() {
        viewportPreviewTiles = []
        currentVisibleRect = nil
        if !detailPreviewTiles.isEmpty { detailPreviewTiles = [] }
    }

    private func cancelPendingViewportWork() {
        detailRenderTask?.cancel()
        detailRenderTask = nil
        // Cancel any coalesced pending viewport render so a stale geometry
        // cannot fire after the caches have been invalidated.
        viewportSchedulerTask?.cancel()
        viewportSchedulerTask = nil
        pendingViewportGeometry = nil
        pendingViewportMissingFlags = []
        detailGeneration &+= 1
    }

    /// Invalidates tile caches. `clearSource` also drops the unedited "before"
    /// tiles (source decode changed); otherwise only chemistry-dependent
    /// "after" tiles are dropped.
    private func cancelDetailWork(clearSource: Bool) {
        cancelPendingViewportWork()
        detailCacheEpoch &+= 1
        detailTileCache = detailTileCache.filter { !$0.key.rendered }
        detailTileLRU.removeAll { $0.rendered }
        detailDraftTileCache = detailDraftTileCache.filter { !$0.key.rendered }
        detailDraftTileLRU.removeAll { $0.rendered }
        viewportTileCache[true] = nil
        if clearSource {
            sourceCacheEpoch &+= 1
            detailTileCache.removeAll(keepingCapacity: false)
            detailTileLRU.removeAll(keepingCapacity: false)
            detailDraftTileCache.removeAll(keepingCapacity: false)
            detailDraftTileLRU.removeAll(keepingCapacity: false)
            viewportTileCache.removeAll(keepingCapacity: false)
        }
    }

    private func detailKeysCovering(_ rect: CGRect, rendered: Bool) -> [DetailTileKey] {
        let tile = CGFloat(detailTileSize)
        let minX = max(0, Int(floor(rect.minX / tile)))
        let minY = max(0, Int(floor(rect.minY / tile)))
        let maxX = max(minX, Int(floor(max(rect.minX, rect.maxX - 1) / tile)))
        let maxY = max(minY, Int(floor(max(rect.minY, rect.maxY - 1) / tile)))
        let generation = rendered ? detailCacheEpoch : sourceCacheEpoch
        var result: [DetailTileKey] = []
        for y in minY...maxY {
            for x in minX...maxX {
                result.append(DetailTileKey(x: x, y: y, rendered: rendered, generation: generation))
            }
        }
        return result
    }

    private func detailCoreRect(for key: DetailTileKey) -> CGRect {
        let tile = CGFloat(detailTileSize)
        return CGRect(x: CGFloat(key.x) * tile, y: CGFloat(key.y) * tile, width: tile, height: tile)
            .intersection(CGRect(origin: .zero, size: images.sourcePixelSize)).integral
    }

    private func insertDetailTile(_ tile: PreviewDetailTile, for key: DetailTileKey) {
        detailTileCache[key] = tile
        detailTileLRU.removeAll { $0 == key }
        detailTileLRU.append(key)
        while detailTileLRU.count > detailTileCacheLimit, let evict = detailTileLRU.first {
            detailTileLRU.removeFirst()
            detailTileCache.removeValue(forKey: evict)
        }
    }

    private func resumeBackgroundPreviewsIfNeeded(parameters: RenderParameters, delayMilliseconds: Int = 600) {
        guard detailRenderTask == nil else { return }
        guard previews.backgroundPreviewsSuspended else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard let self, self.detailRenderTask == nil else { return }
            self.previews.resumeBackgroundPreviewsIfNeeded(parameters: parameters)
        }
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

    nonisolated private static func cropLinearImage(_ image: LinearRGBImage, x: Int, y: Int, width: Int, height: Int) -> LinearRGBImage {
        let sx = min(max(0, x), image.width - 1)
        let sy = min(max(0, y), image.height - 1)
        let w = min(max(1, width), image.width - sx)
        let h = min(max(1, height), image.height - sy)
        var pixels = [Double](repeating: 0, count: w * h * 3)
        for row in 0..<h {
            let src = ((sy + row) * image.width + sx) * 3
            let dst = row * w * 3
            pixels[dst..<(dst + w * 3)] = image.pixels[src..<(src + w * 3)]
        }
        return LinearRGBImage(width: w, height: h, pixels: pixels)
    }
}
#endif
