//
//  ViewportServiceTests.swift
//  SpektrafilmAppTests
//

import AppKit
import Foundation
import Testing
import SpektrafilmCore
import SpektrafilmPreviewGeometry
@testable import SpektrafilmApp

@MainActor
struct ViewportServiceTests {

    private func makeService(
        profiles: FakeProfiles? = nil,
        images: FakeImageSource? = nil,
        renderState: FakeRenderState? = nil,
        previews: FakeBackgroundPreviews? = nil,
        decoder: FakeViewportDecoder? = nil,
        imageRenderer: FakeViewportImageRenderer? = nil
    ) -> (ViewportService, FakeProfiles, FakeImageSource, FakeBackgroundPreviews, CallCounter) {
        let profiles = profiles ?? FakeProfiles()
        let images = images ?? FakeImageSource()
        let renderState = renderState ?? FakeRenderState()
        let previews = previews ?? FakeBackgroundPreviews()
        let counter = CallCounter()
        let decoder = decoder ?? FakeViewportDecoder(counter: counter)
        let imageRenderer = imageRenderer ?? FakeViewportImageRenderer(counter: CallCounter())
        let service = ViewportService(
            profiles: profiles,
            images: images,
            renderState: renderState,
            previews: previews,
            decoder: decoder,
            imageRenderer: imageRenderer
        )
        return (service, profiles, images, previews, counter)
    }

    private func geometry(sourceSize: CGSize, viewport: CGFloat, zoom: CGFloat) -> PreviewGeometry {
        PreviewGeometryCalculator.calculate(
            viewportBounds: CGRect(x: 0, y: 0, width: viewport, height: viewport),
            sourceSize: sourceSize,
            zoom: zoom,
            pan: .zero,
            backingScale: 1,
            matInset: 0
        )
    }

    private func parameters() -> RenderParameters {
        var p = RenderParameters()
        p.debug.enableFixedTileRefinement = false
        return p
    }

    private func preparedImages() -> FakeImageSource {
        let images = FakeImageSource()
        images.sourceURL = URL(fileURLWithPath: "/tmp/source.tif")
        images.sourcePixelSize = CGSize(width: 1000, height: 1000)
        return images
    }

    @Test func belowThresholdDoesNotRender() async throws {
        let images = preparedImages()
        let (service, _, _, _, counter) = makeService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 10000, height: 10000), viewport: 200, zoom: 1)
        #expect(geo.imageScale < 0.20)

        service.requestViewportPreview(geo, rendered: false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(300))

        #expect(counter.count == 0)
        #expect(service.detailPreviewTiles.isEmpty)
    }

    @Test func rendersViewportTileForVisibleRegion() async throws {
        let images = preparedImages()
        let (service, _, _, previews, counter) = makeService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))

        #expect(counter.count == 3)
        #expect(service.detailPreviewTiles.count == 1)
        #expect(previews.suspendCount == 1)
    }

    @Test func coalescesRapidRequestsIntoOneRender() async throws {
        let images = preparedImages()
        let (service, _, _, _, counter) = makeService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: false, parameters: parameters())
        service.requestViewportPreview(geo, rendered: false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))

        #expect(counter.count == 3)
    }

    @Test func invalidateClearsPublishedTiles() async throws {
        let images = preparedImages()
        let (service, _, _, _, _) = makeService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        #expect(service.detailPreviewTiles.isEmpty == false)

        service.invalidateDetailTiles()

        #expect(service.detailPreviewTiles.isEmpty)
    }

    @Test func cropDisablesViewportRendering() async throws {
        let images = preparedImages()
        let (service, _, _, _, counter) = makeService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)
        var p = parameters()
        p.io.crop = true

        service.requestViewportPreview(geo, rendered: false, parameters: p)
        try await Task.sleep(for: .milliseconds(300))

        #expect(counter.count == 0)
        #expect(service.detailPreviewTiles.isEmpty)
    }

    // MARK: - Compare / slider tile sets

    private func makeProfile(id: String) throws -> FilmProfile {
        let object: [String: Any] = ["metadata": [:], "info": ["stock": id, "stage": "filming"], "data": [:]]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(FilmProfile.self, from: data)
    }

    /// Film selected, no print/resources: forces the CPU chemistry path so the
    /// image-renderer counter distinguishes rendered from original passes.
    private func makeCountingService(images: FakeImageSource) throws -> (ViewportService, CallCounter, CallCounter) {
        let profiles = FakeProfiles()
        profiles.filmProfiles = [try makeProfile(id: "film-a")]
        profiles.selectedFilmID = "film-a"
        profiles.selectedPrintID = nil
        let decodeCounter = CallCounter()
        let renderCounter = CallCounter()
        let service = ViewportService(
            profiles: profiles,
            images: images,
            renderState: FakeRenderState(),
            previews: FakeBackgroundPreviews(),
            decoder: FakeViewportDecoder(counter: decodeCounter),
            imageRenderer: FakeViewportImageRenderer(counter: renderCounter)
        )
        return (service, decodeCounter, renderCounter)
    }

    @Test func compareModeRendersOriginalTileSet() async throws {
        let images = preparedImages()
        let (service, _, renderCounter) = try makeCountingService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        #expect(service.detailPreviewTiles.contains { $0.rendered })
        let chemistryAfterFirst = renderCounter.count
        #expect(chemistryAfterFirst == 3)

        service.compareModeDidChange(showOriginal: true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))

        #expect(service.detailPreviewTiles.contains { !$0.rendered })
        #expect(!service.detailPreviewTiles.contains { $0.rendered })
        #expect(renderCounter.count == chemistryAfterFirst, "Original pass must not run chemistry")
    }

    @Test func compareModeNoOpWhenFlagUnchanged() async throws {
        let images = preparedImages()
        let (service, decodeCounter, _) = try makeCountingService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        let after = decodeCounter.count

        service.compareModeDidChange(showOriginal: false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(300))

        #expect(decodeCounter.count == after)
    }

    @Test func sliderRendersBothTileSets() async throws {
        let images = preparedImages()
        let (service, _, renderCounter) = try makeCountingService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        let chemistryAfterFirst = renderCounter.count

        service.setComparisonSliderActive(true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(800))

        #expect(service.detailPreviewTiles.contains { $0.rendered })
        #expect(service.detailPreviewTiles.contains { !$0.rendered })
        #expect(renderCounter.count == chemistryAfterFirst, "Cached after set must not re-run chemistry")
    }

    @Test func sliderDeactivationDropsOriginalTiles() async throws {
        let images = preparedImages()
        let (service, _, _) = try makeCountingService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        service.setComparisonSliderActive(true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(800))
        #expect(service.detailPreviewTiles.contains { !$0.rendered })

        service.setComparisonSliderActive(false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(800))

        #expect(service.detailPreviewTiles.contains { $0.rendered })
        #expect(!service.detailPreviewTiles.contains { !$0.rendered })
    }

    // MARK: - Viewport tile caching

    @Test func compareToggleReusesCachedTileSets() async throws {
        let images = preparedImages()
        let (service, decodeCounter, renderCounter) = try makeCountingService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        #expect(decodeCounter.count == 3)

        // Toggle to original: cache miss for the before set, so it renders.
        service.compareModeDidChange(showOriginal: true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        #expect(service.detailPreviewTiles.contains { !$0.rendered })
        let decodeAfterBefore = decodeCounter.count
        let chemistryAfterBefore = renderCounter.count

        // Toggle back: the after set is cached, so no re-render.
        service.compareModeDidChange(showOriginal: false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(400))
        #expect(decodeCounter.count == decodeAfterBefore)
        #expect(renderCounter.count == chemistryAfterBefore)
        #expect(service.detailPreviewTiles.contains { $0.rendered })
        #expect(!service.detailPreviewTiles.contains { !$0.rendered })
    }

    @Test func sliderReusesCachedAfterSet() async throws {
        let images = preparedImages()
        let (service, decodeCounter, renderCounter) = try makeCountingService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        let decodeAfterRender = decodeCounter.count
        let chemistryAfterRender = renderCounter.count

        // Slider activation reuses the cached after set and renders only before.
        service.setComparisonSliderActive(true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(800))
        #expect(service.detailPreviewTiles.contains { $0.rendered })
        #expect(service.detailPreviewTiles.contains { !$0.rendered })
        #expect(decodeCounter.count == decodeAfterRender + 3, "Only the before set should decode")
        #expect(renderCounter.count == chemistryAfterRender, "After set is reused from cache")

        // Deactivation is a cache hit for the after set.
        service.setComparisonSliderActive(false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(400))
        #expect(decodeCounter.count == decodeAfterRender + 3)
        #expect(renderCounter.count == chemistryAfterRender)
    }

    @Test func chemistryInvalidationKeepsBeforeCache() async throws {
        let images = preparedImages()
        let (service, decodeCounter, _) = try makeCountingService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        #expect(decodeCounter.count == 3)

        // Chemistry/parameter change must not invalidate the source-keyed before set.
        service.invalidateDetailTiles()
        service.requestViewportPreview(geo, rendered: false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(400))

        #expect(decodeCounter.count == 3, "Before tiles should be served from cache")
        #expect(service.detailPreviewTiles.contains { !$0.rendered })
    }

    @Test func sourceInvalidationClearsBeforeCache() async throws {
        let images = preparedImages()
        let (service, decodeCounter, _) = try makeCountingService(images: images)
        let geo = geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1)

        service.requestViewportPreview(geo, rendered: false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        #expect(decodeCounter.count == 3)

        service.sourceDidChange()
        service.requestViewportPreview(geo, rendered: false, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))

        #expect(decodeCounter.count == 6, "Source change must invalidate the before set")
    }

    @Test func viewportMoveInvalidatesCache() async throws {
        let images = preparedImages()
        let (service, decodeCounter, _) = try makeCountingService(images: images)

        service.requestViewportPreview(geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 1),
                                       rendered: true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))
        let afterFirst = decodeCounter.count

        service.requestViewportPreview(geometry(sourceSize: CGSize(width: 1000, height: 1000), viewport: 800, zoom: 2),
                                       rendered: true, parameters: parameters())
        try await Task.sleep(for: .milliseconds(600))

        #expect(decodeCounter.count > afterFirst, "Moved viewport must re-render")
    }
}

// MARK: - Fakes

nonisolated struct FakeViewportDecoder: ViewportDecoding {
    let counter: CallCounter
    var image = LinearRGBImage(width: 4, height: 4, repeating: 0.5)

    func loadRegion(url: URL, rect: CGRect, rawAdjustments: RAWAdjustments, isRAW: Bool, outputScale: Double) async throws -> LinearRGBImage {
        counter.increment()
        return image
    }

    func makeNSImage(_ image: LinearRGBImage, encodeSRGB: Bool) async -> NSImage? {
        NSImage(size: NSSize(width: 2, height: 2))
    }
}

nonisolated struct FakeViewportImageRenderer: ViewportImageRendering {
    let counter: CallCounter

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
        counter.increment()
        return LinearRGBImage(width: 4, height: 4, repeating: 0.25)
    }
}

@MainActor
private final class FakeProfiles: ProfileProviding {
    var filmProfiles: [FilmProfile] = []
    var printProfiles: [FilmProfile] = []
    var selectedFilmID: String?
    var selectedPrintID: String?
    var pipelineResources: PipelineResources?
    var prewarmTask: Task<(), Never>?

    var selectedFilm: FilmProfile? { filmProfiles.first { $0.id == selectedFilmID } }
    var selectedPrint: FilmProfile? { printProfiles.first { $0.id == selectedPrintID } }
}

@MainActor
private final class FakeImageSource: ImageSourceProviding {
    var sourceImage: LinearRGBImage?
    var sourcePixelSize: CGSize = .zero
    var isRAWSource = false
    var rawAdjustments = RAWAdjustments.default
    var sourceImageRevision: UInt = 0
    var sourceURL: URL?
    var originalPreview: NSImage?
    var cachedPreviewSource: LinearRGBImage?
    var cachedPreviewMaxSize = 0

    func storePreviewProxy(_ image: LinearRGBImage, maxSize: Int) {
        cachedPreviewSource = image
        cachedPreviewMaxSize = maxSize
    }
}

@MainActor
private final class FakeRenderState: PreviewRenderStateReading {
    var isRendering = false
    var lastAutoExposureEV: Double = 0
}

@MainActor
private final class FakeBackgroundPreviews: BackgroundPreviewCoordinating {
    private(set) var backgroundPreviewsSuspended = false
    private(set) var suspendCount = 0
    private(set) var resumeCount = 0

    func suspendBackgroundPreviews() {
        backgroundPreviewsSuspended = true
        suspendCount += 1
    }

    func resumeBackgroundPreviewsIfNeeded(parameters: RenderParameters) {
        resumeCount += 1
        backgroundPreviewsSuspended = false
    }
}
