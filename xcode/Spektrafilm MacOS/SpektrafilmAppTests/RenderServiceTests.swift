//
//  RenderServiceTests.swift
//  SpektrafilmAppTests
//

import AppKit
import Foundation
import Testing
import SpektrafilmCore
@testable import SpektrafilmApp

@MainActor
struct RenderServiceTests {

    private func makeProfile(id: String) throws -> FilmProfile {
        let object: [String: Any] = ["metadata": [:], "info": ["stock": id, "stage": "filming"], "data": [:]]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(FilmProfile.self, from: data)
    }

    private func makeService(
        profiles: FakeProfiles? = nil,
        images: FakeImageSource? = nil,
        executor: FakeRenderExecutor = FakeRenderExecutor(),
        delegate: SpyRenderServiceDelegate? = nil
    ) -> (RenderService, FakeProfiles, FakeImageSource, SpyRenderServiceDelegate) {
        let profiles = profiles ?? FakeProfiles()
        let images = images ?? FakeImageSource()
        let delegate = delegate ?? SpyRenderServiceDelegate()
        let service = RenderService(profiles: profiles, images: images, executor: executor)
        service.delegate = delegate
        return (service, profiles, images, delegate)
    }

    @Test func rendersImmediatelyAndPublishesPreview() async throws {
        let profiles = FakeProfiles()
        let film = try makeProfile(id: "film-a")
        profiles.filmProfiles = [film]
        profiles.selectedFilmID = "film-a"
        let images = FakeImageSource()
        images.sourceImage = LinearRGBImage(width: 4, height: 4, repeating: 0.5)
        let result = RenderResult(
            image: LinearRGBImage(width: 4, height: 4, repeating: 0.25),
            autoExposureEV: 1.25,
            stage: .output
        )
        let (service, _, _, delegate) = makeService(
            profiles: profiles,
            images: images,
            executor: FakeRenderExecutor(result: result)
        )

        service.renderImmediately(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(300))

        #expect(service.previewImage != nil)
        #expect(service.lastAutoExposureEV == 1.25)
        #expect(service.isRendering == false)
        #expect(service.renderProgress == nil)
        #expect(delegate.willBeginCount == 1)
        #expect(delegate.completeCount == 1)
        #expect(delegate.statuses.contains { $0.hasPrefix("Rendered") })
    }

    @Test func renderWithoutSourceIsNoOp() async throws {
        let profiles = FakeProfiles()
        profiles.filmProfiles = [try makeProfile(id: "film-a")]
        profiles.selectedFilmID = "film-a"
        let (service, _, _, delegate) = makeService(profiles: profiles)

        service.renderImmediately(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(200))

        #expect(service.previewImage == nil)
        #expect(delegate.willBeginCount == 0)
        #expect(delegate.statuses.isEmpty)
    }

    @Test func renderWithoutFilmIsNoOp() async throws {
        let images = FakeImageSource()
        images.sourceImage = LinearRGBImage(width: 4, height: 4, repeating: 0.5)
        let (service, _, _, delegate) = makeService(images: images)

        service.renderImmediately(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(200))

        #expect(service.previewImage == nil)
        #expect(delegate.willBeginCount == 0)
    }

    @Test func renderFailureReportsStatus() async throws {
        let profiles = FakeProfiles()
        profiles.filmProfiles = [try makeProfile(id: "film-a")]
        profiles.selectedFilmID = "film-a"
        let images = FakeImageSource()
        images.sourceImage = LinearRGBImage(width: 4, height: 4, repeating: 0.5)
        var executor = FakeRenderExecutor()
        executor.shouldFail = true
        let (service, _, _, delegate) = makeService(profiles: profiles, images: images, executor: executor)

        service.renderImmediately(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(300))

        #expect(service.isRendering == false)
        #expect(service.previewImage == nil)
        #expect(delegate.statuses.contains { $0.hasPrefix("Render failed") })
    }

    @Test func cancelRenderResetsStateAndStatus() async throws {
        let (service, _, _, delegate) = makeService()
        service.isRendering = true
        service.renderProgress = 0.5
        service.renderDetached = Task { try await Task.sleep(for: .seconds(30)) }

        service.cancelRender()

        #expect(service.isRendering == false)
        #expect(service.renderProgress == nil)
        #expect(service.renderDetached == nil)
        #expect(delegate.statuses.last == "Render cancelled.")
    }

    @Test func cachesResizedProxyOnCacheMiss() async throws {
        let profiles = FakeProfiles()
        profiles.filmProfiles = [try makeProfile(id: "film-a")]
        profiles.selectedFilmID = "film-a"
        let images = FakeImageSource()
        images.sourceImage = LinearRGBImage(width: 8, height: 8, repeating: 0.5)
        let result = RenderResult(
            image: LinearRGBImage(width: 8, height: 8, repeating: 0.25),
            autoExposureEV: 0,
            stage: .output
        )
        let (service, _, _, _) = makeService(
            profiles: profiles,
            images: images,
            executor: FakeRenderExecutor(result: result)
        )

        service.renderImmediately(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(300))

        #expect(images.storedProxyMaxSizes.count == 1)
        #expect(images.cachedPreviewSource != nil)
    }
}

// MARK: - Fakes

private enum FakeRenderError: Error, Sendable { case boom }

nonisolated struct FakeRenderExecutor: RenderExecuting {
    var result = RenderResult(
        image: LinearRGBImage(width: 1, height: 1, repeating: 0),
        autoExposureEV: 0,
        stage: .output
    )
    var shouldFail = false

    func render(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters,
        resources: PipelineResources?,
        progress: @escaping @Sendable (Double, String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> RenderResult {
        progress(0.5, "Halfway")
        if shouldFail { throw FakeRenderError.boom }
        return result
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
    private(set) var storedProxyMaxSizes: [Int] = []

    func storePreviewProxy(_ image: LinearRGBImage, maxSize: Int) {
        cachedPreviewSource = image
        cachedPreviewMaxSize = maxSize
        storedProxyMaxSizes.append(maxSize)
    }
}

@MainActor
private final class SpyRenderServiceDelegate: RenderServiceDelegate {
    var statuses: [String] = []
    var willBeginCount = 0
    var completeCount = 0

    func renderService(_ service: RenderService, didUpdateStatus status: String) {
        statuses.append(status)
    }

    func renderServiceWillBeginRender(_ service: RenderService) { willBeginCount += 1 }

    func renderServiceDidCompleteRender(_ service: RenderService) { completeCount += 1 }
}
