//
//  ProfilePreviewsServiceTests.swift
//  SpektrafilmAppTests
//

import AppKit
import Foundation
import Testing
import SpektrafilmCore
@testable import SpektrafilmApp

@MainActor
struct ProfilePreviewsServiceTests {

    private func makeProfile(id: String, stage: String) throws -> FilmProfile {
        let object: [String: Any] = ["metadata": [:], "info": ["stock": id, "stage": stage], "data": [:]]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(FilmProfile.self, from: data)
    }

    private func makeService(
        profiles: FakeProfiles? = nil,
        images: FakeImageSource? = nil,
        renderer: FakePreviewRenderer? = nil
    ) -> (ProfilePreviewsService, FakeProfiles, FakeImageSource) {
        let profiles = profiles ?? FakeProfiles()
        let images = images ?? FakeImageSource()
        let renderer = renderer ?? FakePreviewRenderer(counter: CallCounter())
        let service = ProfilePreviewsService(profiles: profiles, images: images, renderer: renderer)
        return (service, profiles, images)
    }

    @Test func sourceDidChangePopulatesBothGrids() async throws {
        let profiles = FakeProfiles()
        profiles.filmProfiles = [try makeProfile(id: "film-a", stage: "filming"), try makeProfile(id: "film-b", stage: "filming")]
        profiles.printProfiles = [try makeProfile(id: "paper-a", stage: "printing"), try makeProfile(id: "paper-b", stage: "printing")]
        profiles.selectedFilmID = "film-a"
        let images = FakeImageSource()
        images.sourceImage = LinearRGBImage(width: 8, height: 8, repeating: 0.5)
        let (service, _, _) = makeService(profiles: profiles, images: images)

        service.sourceDidChange(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(300))

        #expect(service.filmPreviewImages.count == 2)
        #expect(service.printPreviewImages.count == 2)
        #expect(service.printPreviewNoneImage != nil)
        #expect(service.isRenderingFilmPreviews == false)
        #expect(service.isRenderingPreviews == false)
    }

    @Test func withoutSourceClearsGrids() async throws {
        let profiles = FakeProfiles()
        profiles.printProfiles = [try makeProfile(id: "paper-a", stage: "printing")]
        let (service, _, _) = makeService(profiles: profiles)

        service.sourceDidChange(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(200))

        #expect(service.printPreviewImages.isEmpty)
        #expect(service.printPreviewNoneImage == nil)
    }

    @Test func refreshIsCacheHitForUnchangedEpoch() async throws {
        let profiles = FakeProfiles()
        profiles.printProfiles = [try makeProfile(id: "paper-a", stage: "printing")]
        profiles.selectedFilmID = "film-a"
        let film = try makeProfile(id: "film-a", stage: "filming")
        profiles.filmProfiles = [film]
        let images = FakeImageSource()
        images.sourceImage = LinearRGBImage(width: 8, height: 8, repeating: 0.5)
        let counter = CallCounter()
        let renderer = FakePreviewRenderer(counter: counter)
        let (service, _, _) = makeService(profiles: profiles, images: images, renderer: renderer)

        service.sourceDidChange(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(300))
        let callsAfterFirstRefresh = counter.count

        service.refreshPrintPreviews(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(200))

        #expect(counter.count == callsAfterFirstRefresh)
    }

    @Test func suspendThenResumeRefreshesStaleGrid() async throws {
        let profiles = FakeProfiles()
        profiles.printProfiles = [try makeProfile(id: "paper-a", stage: "printing")]
        profiles.filmProfiles = [try makeProfile(id: "film-a", stage: "filming")]
        profiles.selectedFilmID = "film-a"
        let images = FakeImageSource()
        images.sourceImage = LinearRGBImage(width: 8, height: 8, repeating: 0.5)
        let counter = CallCounter()
        let renderer = FakePreviewRenderer(counter: counter)
        let (service, _, _) = makeService(profiles: profiles, images: images, renderer: renderer)

        service.sourceDidChange(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(300))

        // Make the print grid stale, then suspend before the debounce fires.
        service.scheduleProfilePreviewRefreshes(film: false, print: true, parameters: RenderParameters())
        service.suspendBackgroundPreviews()
        #expect(service.backgroundPreviewsSuspended == true)

        service.resumeBackgroundPreviewsIfNeeded(parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(300))

        #expect(service.backgroundPreviewsSuspended == false)
        #expect(service.printPreviewImages.count == 1)
    }
}

// MARK: - Fakes

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

nonisolated struct FakePreviewRenderer: PreviewThumbnailRendering {
    let counter: CallCounter
    var result = LinearRGBImage(width: 2, height: 2, repeating: 0.5)

    func render(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters,
        resources: PipelineResources?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> LinearRGBImage {
        counter.increment()
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

    func storePreviewProxy(_ image: LinearRGBImage, maxSize: Int) {
        cachedPreviewSource = image
        cachedPreviewMaxSize = maxSize
    }
}
