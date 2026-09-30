#if os(macOS)
import AppKit
import Foundation
import SpektrafilmCore
import UniformTypeIdentifiers

/// UI-side reactions to exporting (status text).
@MainActor
protocol ExportServiceDelegate: AnyObject {
    func exportService(_ service: ExportService, didUpdateStatus status: String)
}

/// The transient render presentation state an export drives while it works, so
/// the main preview shows progress/cancel and the exported preview image.
@MainActor
protocol RenderJobPresenting: AnyObject {
    var isRendering: Bool { get set }
    var renderProgress: Double? { get set }
    var pendingRenderResult: RenderResult? { get set }
    var renderDetached: Task<(), Error>? { get set }
    var previewImage: NSImage? { get set }
}

/// Seam over full-resolution decode/encode, which are MainActor-bound.
nonisolated protocol ExportDecoding: Sendable {
    func loadSourceLinearSRGB(url: URL, rawAdjustments: RAWAdjustments, isRAW: Bool) async throws -> LinearRGBImage
    func makeNSImage(_ image: LinearRGBImage, encodeSRGB: Bool) async -> NSImage?
    func save(
        _ image: LinearRGBImage,
        to url: URL,
        settings: ExportSettings,
        outputColorSpace: String,
        pixelsAreTransferEncoded: Bool,
        metadataSourceURL: URL?
    ) async throws
}

nonisolated struct LiveExportDecoder: ExportDecoding {
    func loadSourceLinearSRGB(url: URL, rawAdjustments: RAWAdjustments, isRAW: Bool) async throws -> LinearRGBImage {
        try await ImageCodec.loadSourceLinearSRGB(url: url, rawAdjustments: rawAdjustments, isRAW: isRAW)
    }

    func makeNSImage(_ image: LinearRGBImage, encodeSRGB: Bool) async -> NSImage? {
        await ImageCodec.makeNSImage(image, encodeSRGB: encodeSRGB)
    }

    func save(
        _ image: LinearRGBImage,
        to url: URL,
        settings: ExportSettings,
        outputColorSpace: String,
        pixelsAreTransferEncoded: Bool,
        metadataSourceURL: URL?
    ) async throws {
        try await ImageCodec.save(
            image,
            to: url,
            settings: settings,
            outputColorSpace: outputColorSpace,
            pixelsAreTransferEncoded: pixelsAreTransferEncoded,
            metadataSourceURL: metadataSourceURL
        )
    }
}

/// Seam over the save panel so tests can drive export without a modal.
@MainActor
protocol ExportFilePicking: AnyObject {
    func chooseSaveURL(suggestedName: String, contentType: UTType) async -> URL?
}

@MainActor
final class LiveExportFilePicker: ExportFilePicking {
    func chooseSaveURL(suggestedName: String, contentType: UTType) async -> URL? {
        // ContentView calls this only after the SwiftUI export sheet's onDismiss
        // callback, so the sheet has fully detached by the time the panel is
        // presented and there is no overlapping modal transition. Use the
        // asynchronous panel API rather than runModal() to avoid starting a
        // nested AppKit modal event loop.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

/// Full-resolution export: decode the source, run the pipeline in export mode,
/// then encode and save. Reads source/profiles through their provider
/// protocols and drives the shared render presentation state.
@MainActor
final class ExportService {
    weak var delegate: ExportServiceDelegate?

    private let profiles: ProfileProviding
    private let images: ImageSourceProviding
    private let renderState: RenderJobPresenting
    private let executor: RenderExecuting
    private let decoder: ExportDecoding
    private let picker: ExportFilePicking

    init(profiles: ProfileProviding,
         images: ImageSourceProviding,
         renderState: RenderJobPresenting,
         executor: RenderExecuting = LiveRenderExecutor(),
         decoder: ExportDecoding = LiveExportDecoder(),
         picker: ExportFilePicking = LiveExportFilePicker()) {
        self.profiles = profiles
        self.images = images
        self.renderState = renderState
        self.executor = executor
        self.decoder = decoder
        self.picker = picker
    }

    func exportImage(settings: ExportSettings, parameters: RenderParameters) {
        guard let sourceURL = images.sourceURL else {
            AppLog.warning("app", "Export attempted with no source image")
            return
        }
        guard let film = profiles.selectedFilm else {
            AppLog.warning("app", "Export attempted with no film profile selected")
            return
        }
        let paper = profiles.selectedPrint
        var p = parameters
        p.settings.previewMode = false
        let resources = profiles.pipelineResources
        let fullSize = images.sourcePixelSize
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let suggestedName = "\(baseName)-spektrafilm.\(settings.format.fileExtension)"
        let contentType = settings.format.contentType

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = await self.picker.chooseSaveURL(suggestedName: suggestedName, contentType: contentType) else {
                AppLog.info("app", "Export cancelled")
                return
            }
            self.performExport(
                to: url,
                sourceURL: sourceURL,
                film: film,
                paper: paper,
                parameters: p,
                resources: resources,
                fullSize: fullSize,
                settings: settings
            )
        }
    }

    private func performExport(
        to url: URL,
        sourceURL: URL,
        film: FilmProfile,
        paper: FilmProfile?,
        parameters p: RenderParameters,
        resources: PipelineResources?,
        fullSize: CGSize,
        settings: ExportSettings
    ) {
        let depth = settings.effectiveBitDepth.rawValue
        AppLog.info("app", "Exporting \(settings.format.rawValue) \(depth)-bit to \(url.path)")
        renderState.isRendering = true
        renderState.renderProgress = 0
        delegate?.exportService(self, didUpdateStatus: "Decoding full-resolution source…")
        let filmID = film.id, filmName = film.info.name ?? filmID
        let paperID = paper?.id ?? "none (scan film directly)"
        AppLog.info("app", "Render start: film='\(filmName)' (\(filmID)), print='\(paperID)', \(Int(fullSize.width))×\(Int(fullSize.height)), scanFilm=\(p.scanFilm)")
        let start = ContinuousClock.now
        renderState.renderDetached?.cancel()
        let renderParams = p
        let renderIsRAW = images.isRAWSource
        let renderParamsRAW = images.rawAdjustments
        let executor = self.executor
        let decoder = self.decoder
        let detached = Task.detached(priority: .userInitiated) { [weak self] in
            let decodeStart = ContinuousClock.now
            let input = try await decoder.loadSourceLinearSRGB(url: sourceURL, rawAdjustments: renderParamsRAW, isRAW: renderIsRAW)
            AppLog.info("app", "Full-resolution decode for export: \(input.width)×\(input.height) in \(AppLog.formatElapsed(AppLog.msSince(decodeStart)))")
            let result = try executor.render(
                input: input,
                film: film,
                print: paper,
                parameters: renderParams,
                resources: resources,
                progress: { [weak self] fraction, label in
                    Task { @MainActor in
                        self?.renderState.renderProgress = fraction
                        self?.delegate?.exportService(self!, didUpdateStatus: "Rendering: \(label)")
                    }
                },
                isCancelled: { Task.isCancelled }
            )
            await MainActor.run { [weak self] in self?.renderState.pendingRenderResult = result }
        }
        renderState.renderDetached = detached
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await detached.value
                guard let result = self.renderState.pendingRenderResult else { throw ImageCodec.CodecError.encode }
                let preview = await self.decoder.makeNSImage(result.image, encodeSRGB: !p.io.outputCCTFEncoding)
                self.renderState.renderDetached = nil
                if let preview { self.renderState.previewImage = preview }
                self.delegate?.exportService(self, didUpdateStatus: "Encoding \(settings.format.rawValue)…")

                try await self.decoder.save(
                    result.image,
                    to: url,
                    settings: settings,
                    outputColorSpace: p.io.outputColorSpace,
                    pixelsAreTransferEncoded: p.io.outputCCTFEncoding,
                    metadataSourceURL: sourceURL
                )

                self.renderState.isRendering = false
                self.renderState.renderProgress = nil
                AppLog.info("app", "Exported '\(url.lastPathComponent)' (\(result.image.width)×\(result.image.height), \(settings.format.rawValue), \(depth)-bit) to \(url.path) in \(AppLog.formatElapsed(AppLog.msSince(start)))")
                self.delegate?.exportService(self, didUpdateStatus: "Exported \(url.lastPathComponent).")
            } catch is CancellationError {
                self.renderState.renderDetached = nil
                self.renderState.isRendering = false
                self.renderState.renderProgress = nil
                self.delegate?.exportService(self, didUpdateStatus: "Export cancelled.")
                AppLog.info("app", "Export cancelled mid-render")
            } catch {
                self.renderState.renderDetached = nil
                self.renderState.isRendering = false
                self.renderState.renderProgress = nil
                AppLog.error("app", "Export failed for \(url.path): \(error)")
                self.delegate?.exportService(self, didUpdateStatus: "Export failed: \(error.localizedDescription)")
            }
        }
    }
}
#endif
