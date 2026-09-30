//
//  ExportServiceTests.swift
//  SpektrafilmAppTests
//

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import SpektrafilmCore
@testable import SpektrafilmApp

@MainActor
struct ExportServiceTests {

    private func makeProfile(id: String) throws -> FilmProfile {
        let object: [String: Any] = ["metadata": [:], "info": ["stock": id, "stage": "filming"], "data": [:]]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(FilmProfile.self, from: data)
    }

    private func makeService(
        profiles: FakeProfiles? = nil,
        images: FakeImageSource? = nil,
        renderState: FakeRenderState? = nil,
        executor: FakeExportExecutor = FakeExportExecutor(),
        decoder: FakeExportDecoder? = nil,
        picker: FakeExportPicker? = nil,
        delegate: SpyExportServiceDelegate? = nil
    ) -> (ExportService, FakeProfiles, FakeImageSource, FakeRenderState, FakeExportDecoder, FakeExportPicker, SpyExportServiceDelegate) {
        let profiles = profiles ?? FakeProfiles()
        let images = images ?? FakeImageSource()
        let renderState = renderState ?? FakeRenderState()
        let decoder = decoder ?? FakeExportDecoder(recorder: ExportRecorder())
        let picker = picker ?? FakeExportPicker()
        let delegate = delegate ?? SpyExportServiceDelegate()
        let service = ExportService(
            profiles: profiles,
            images: images,
            renderState: renderState,
            executor: executor,
            decoder: decoder,
            picker: picker
        )
        service.delegate = delegate
        return (service, profiles, images, renderState, decoder, picker, delegate)
    }

    @Test func exportsFileAndPublishesStatus() async throws {
        let profiles = FakeProfiles()
        profiles.filmProfiles = [try makeProfile(id: "film-a")]
        profiles.selectedFilmID = "film-a"
        let images = FakeImageSource()
        images.sourceURL = URL(fileURLWithPath: "/tmp/source.tif")
        images.sourcePixelSize = CGSize(width: 100, height: 80)
        let destination = URL(fileURLWithPath: "/tmp/out.jpg")
        let picker = FakeExportPicker()
        picker.url = destination
        let recorder = ExportRecorder()
        let (service, _, _, renderState, _, _, delegate) = makeService(
            profiles: profiles,
            images: images,
            decoder: FakeExportDecoder(recorder: recorder),
            picker: picker
        )

        service.exportImage(settings: ExportSettings(), parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(500))

        #expect(recorder.savedURLs == [destination])
        #expect(renderState.isRendering == false)
        #expect(renderState.renderProgress == nil)
        #expect(delegate.statuses.contains { $0.hasPrefix("Exported") })
    }

    @Test func cancelledSavePanelDoesNothing() async throws {
        let profiles = FakeProfiles()
        profiles.filmProfiles = [try makeProfile(id: "film-a")]
        profiles.selectedFilmID = "film-a"
        let images = FakeImageSource()
        images.sourceURL = URL(fileURLWithPath: "/tmp/source.tif")
        let picker = FakeExportPicker()
        picker.url = nil
        let recorder = ExportRecorder()
        let (service, _, _, renderState, _, _, delegate) = makeService(
            profiles: profiles,
            images: images,
            decoder: FakeExportDecoder(recorder: recorder),
            picker: picker
        )

        service.exportImage(settings: ExportSettings(), parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(300))

        #expect(recorder.savedURLs.isEmpty)
        #expect(renderState.isRendering == false)
        #expect(delegate.statuses.isEmpty)
    }

    @Test func exportWithoutSourceIsNoOp() async throws {
        let profiles = FakeProfiles()
        profiles.filmProfiles = [try makeProfile(id: "film-a")]
        profiles.selectedFilmID = "film-a"
        let picker = FakeExportPicker()
        picker.url = URL(fileURLWithPath: "/tmp/out.jpg")
        let (service, _, _, _, _, _, delegate) = makeService(profiles: profiles, picker: picker)

        service.exportImage(settings: ExportSettings(), parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(200))

        #expect(picker.chooseCount == 0)
        #expect(delegate.statuses.isEmpty)
    }

    @Test func exportWithoutFilmIsNoOp() async throws {
        let images = FakeImageSource()
        images.sourceURL = URL(fileURLWithPath: "/tmp/source.tif")
        let picker = FakeExportPicker()
        picker.url = URL(fileURLWithPath: "/tmp/out.jpg")
        let (service, _, _, _, _, _, delegate) = makeService(images: images, picker: picker)

        service.exportImage(settings: ExportSettings(), parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(200))

        #expect(picker.chooseCount == 0)
        #expect(delegate.statuses.isEmpty)
    }

    @Test func saveFailureReportsStatus() async throws {
        let profiles = FakeProfiles()
        profiles.filmProfiles = [try makeProfile(id: "film-a")]
        profiles.selectedFilmID = "film-a"
        let images = FakeImageSource()
        images.sourceURL = URL(fileURLWithPath: "/tmp/source.tif")
        let picker = FakeExportPicker()
        picker.url = URL(fileURLWithPath: "/tmp/out.jpg")
        let recorder = ExportRecorder()
        recorder.shouldFailSave = true
        let (service, _, _, renderState, _, _, delegate) = makeService(
            profiles: profiles,
            images: images,
            decoder: FakeExportDecoder(recorder: recorder),
            picker: picker
        )

        service.exportImage(settings: ExportSettings(), parameters: RenderParameters())
        try await Task.sleep(for: .milliseconds(500))

        #expect(renderState.isRendering == false)
        #expect(delegate.statuses.contains { $0.hasPrefix("Export failed") })
    }
}

// MARK: - Fakes

private enum FakeExportError: Error, Sendable { case boom }

final class ExportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _savedURLs: [URL] = []
    var shouldFailSave = false
    func recordSave(_ url: URL) { lock.lock(); _savedURLs.append(url); lock.unlock() }
    var savedURLs: [URL] { lock.lock(); defer { lock.unlock() }; return _savedURLs }
}

nonisolated struct FakeExportDecoder: ExportDecoding {
    let recorder: ExportRecorder
    var image = LinearRGBImage(width: 4, height: 4, repeating: 0.5)

    func loadSourceLinearSRGB(url: URL, rawAdjustments: RAWAdjustments, isRAW: Bool) async throws -> LinearRGBImage {
        image
    }

    func makeNSImage(_ image: LinearRGBImage, encodeSRGB: Bool) async -> NSImage? { nil }

    func save(
        _ image: LinearRGBImage,
        to url: URL,
        settings: ExportSettings,
        outputColorSpace: String,
        pixelsAreTransferEncoded: Bool,
        metadataSourceURL: URL?
    ) async throws {
        if recorder.shouldFailSave { throw FakeExportError.boom }
        recorder.recordSave(url)
    }
}

nonisolated struct FakeExportExecutor: RenderExecuting {
    var result = RenderResult(
        image: LinearRGBImage(width: 4, height: 4, repeating: 0.25),
        autoExposureEV: 0,
        stage: .output
    )

    func render(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters,
        resources: PipelineResources?,
        progress: @escaping @Sendable (Double, String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> RenderResult {
        progress(1.0, "Done")
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

@MainActor
private final class FakeRenderState: RenderJobPresenting {
    var isRendering = false
    var renderProgress: Double?
    var pendingRenderResult: RenderResult?
    var renderDetached: Task<(), Error>?
    var previewImage: NSImage?
}

@MainActor
private final class FakeExportPicker: ExportFilePicking {
    var url: URL?
    private(set) var chooseCount = 0
    func chooseSaveURL(suggestedName: String, contentType: UTType) async -> URL? {
        chooseCount += 1
        return url
    }
}

@MainActor
private final class SpyExportServiceDelegate: ExportServiceDelegate {
    var statuses: [String] = []
    func exportService(_ service: ExportService, didUpdateStatus status: String) {
        statuses.append(status)
    }
}
