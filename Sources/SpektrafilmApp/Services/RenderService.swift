#if os(macOS)
import AppKit
import Combine
import Foundation
import SpektrafilmCore

/// UI-side reactions to preview rendering. `RenderService` owns the render
/// execution state; status text and viewport invalidation stay with the
/// coordinator.
@MainActor
protocol RenderServiceDelegate: AnyObject {
    func renderService(_ service: RenderService, didUpdateStatus status: String)
    func renderServiceWillBeginRender(_ service: RenderService)
    func renderServiceDidCompleteRender(_ service: RenderService)
}

/// Seam over the actual preview pipeline so render orchestration can be tested
/// without Metal or spectral profiles. `nonisolated` so it can run from the
/// detached render task under the app target's default MainActor isolation.
nonisolated protocol RenderExecuting: Sendable {
    func render(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters,
        resources: PipelineResources?,
        progress: @escaping @Sendable (Double, String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> RenderResult
}

nonisolated struct LiveRenderExecutor: RenderExecuting {
    func render(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters,
        resources: PipelineResources?,
        progress: @escaping @Sendable (Double, String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> RenderResult {
        try MetalAccelerator.shared.withWorkPriority(.interactive) {
            try SpektrafilmPipeline.render(
                input: input,
                film: film,
                print: print,
                parameters: parameters,
                resources: resources,
                progress: progress,
                isCancelled: isCancelled
            )
        }
    }
}

/// Owns the main preview render lifecycle: debounce, cancellation, progress,
/// result delivery and the rendered image. It reads source/profiles through
/// their provider protocols and takes the current parameters per request, so it
/// has no back-reference to `AppViewModel`.
@MainActor
final class RenderService: ObservableObject {
    @Published var previewImage: NSImage?
    @Published var isRendering = false
    @Published var renderProgress: Double?

    var pendingRenderResult: RenderResult?
    var renderDetached: Task<(), Error>?
    private var renderDebounceTask: Task<Void, Never>?
    private(set) var lastAutoExposureEV: Double = 0
    private var lastProgressPublicationTime: TimeInterval = 0
    private var lastProgressLabel: String?
    private let renderDebounceSeconds: Double = 2.0

    weak var delegate: RenderServiceDelegate?

    private let profiles: ProfileProviding
    private let images: ImageSourceProviding
    private let executor: RenderExecuting

    init(profiles: ProfileProviding,
         images: ImageSourceProviding,
         executor: RenderExecuting = LiveRenderExecutor()) {
        self.profiles = profiles
        self.images = images
        self.executor = executor
    }

    func requestRender(parameters: RenderParameters) {
        renderImmediately(parameters: parameters)
    }

    /// Continuous editor changes are coalesced so transient floating-point slider
    /// values never launch a full preview render. Discrete actions (open image,
    /// profile selection, Render button) continue to render immediately.
    func requestDebouncedRender(parameters: RenderParameters) {
        renderDebounceTask?.cancel()
        renderDebounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.renderDebounceTask = nil
            AppLog.debug("app", "Main preview debounce elapsed (2 s); rendering stable adjustment state")
            self.render(parameters: parameters)
        }
    }

    /// Explicit/discrete render actions bypass the interactive debounce.
    func renderImmediately(parameters: RenderParameters) {
        renderDebounceTask?.cancel()
        renderDebounceTask = nil
        render(parameters: parameters)
    }

    func cancelRender() {
        renderDebounceTask?.cancel()
        renderDebounceTask = nil
        renderDetached?.cancel()
        renderDetached = nil
        isRendering = false
        renderProgress = nil
        delegate?.renderService(self, didUpdateStatus: "Render cancelled.")
        AppLog.info("app", "Render cancelled by user")
    }

    private func render(parameters: RenderParameters) {
        renderDebounceTask?.cancel()
        renderDebounceTask = nil
        guard let input = images.sourceImage else { AppLog.debug("app", "Render requested but no source image"); return }
        guard let film = profiles.selectedFilm else { AppLog.debug("app", "Render requested but no film profile selected"); return }
        let paper = profiles.selectedPrint
        var p = parameters
        p.settings.previewMode = true
        let resources = profiles.pipelineResources
        isRendering = true
        renderProgress = 0
        lastProgressLabel = nil
        delegate?.renderServiceWillBeginRender(self)
        delegate?.renderService(self, didUpdateStatus: "Rendering…")
        let filmID = film.id
        let filmName = film.info.name ?? filmID
        let paperID = paper?.id ?? "none (scan film directly)"
        AppLog.info("app", "Render start: film='\(filmName)' (\(filmID)), print='\(paperID)', \(input.width)×\(input.height), scanFilm=\(p.scanFilm)")
        let start = ContinuousClock.now
        renderDetached?.cancel()
        let previewMaxSize = max(p.settings.previewMaxSize, 64)
        let cachedWork = (images.cachedPreviewMaxSize == previewMaxSize) ? images.cachedPreviewSource : nil
        let renderParams = p
        let executor = self.executor
        let detached = Task.detached(priority: .userInitiated) { [weak self] in
            let work: LinearRGBImage
            if let cachedWork {
                work = cachedWork
                AppLog.debug("app", "Preview source cache hit: \(work.width)×\(work.height)")
            } else {
                work = Resample.resize(input, maxDimension: previewMaxSize)
                AppLog.info("app", "Preview source cache miss; resized once to \(work.width)×\(work.height)")
                Task { @MainActor [weak self] in
                    guard let self,
                          self.images.sourceImage?.width == input.width,
                          self.images.sourceImage?.height == input.height else { return }
                    self.images.storePreviewProxy(work, maxSize: previewMaxSize)
                }
            }
            if work.width != input.width {
                AppLog.info("app", "Preview render uses \(work.width)×\(work.height) work image")
            }
            let result = try executor.render(
                input: work,
                film: film,
                print: paper,
                parameters: renderParams,
                resources: resources,
                progress: { [weak self] fraction, label in
                    Task { @MainActor in self?.publishRenderProgress(fraction, label: label) }
                },
                isCancelled: { Task.isCancelled }
            )
            await MainActor.run { [weak self] in
                self?.pendingRenderResult = result
            }
        }
        renderDetached = detached
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await detached.value
                let result = self.pendingRenderResult!
                let preview = ImageCodec.makeNSImage(result.image, encodeSRGB: !p.io.outputCCTFEncoding)
                self.renderDetached = nil
                self.previewImage = preview
                self.lastAutoExposureEV = result.autoExposureEV
                self.isRendering = false
                self.renderProgress = nil
                let ms = AppLog.msSince(start)
                AppLog.info("app", "Render complete: \(AppLog.formatElapsed(ms)), auto exposure \(String(format: "%.2f", result.autoExposureEV)) EV, stage=\(result.stage.rawValue)")
                self.delegate?.renderService(self, didUpdateStatus: String(format: "Rendered · auto exposure %.2f EV", result.autoExposureEV))
                self.delegate?.renderServiceDidCompleteRender(self)
            } catch is CancellationError {
                self.renderDetached = nil
                self.isRendering = false
                self.renderProgress = nil
                self.delegate?.renderService(self, didUpdateStatus: "Render cancelled.")
                AppLog.info("app", "Render cancelled mid-render")
            } catch {
                self.renderDetached = nil
                self.isRendering = false
                self.renderProgress = nil
                AppLog.error("app", "Render failed: \(error)")
                self.delegate?.renderService(self, didUpdateStatus: "Render failed: \(error.localizedDescription)")
            }
        }
    }

    private func publishRenderProgress(_ fraction: Double, label: String) {
        let now = Date.timeIntervalSinceReferenceDate
        let shouldPublish = fraction >= 0.999 || now - lastProgressPublicationTime >= 0.10
        guard shouldPublish else { return }
        lastProgressPublicationTime = now
        if renderProgress == nil || abs((renderProgress ?? 0) - fraction) >= 0.005 {
            renderProgress = fraction
        }
        let nextStatus = "Rendering: \(label)"
        if lastProgressLabel != nextStatus {
            lastProgressLabel = nextStatus
            delegate?.renderService(self, didUpdateStatus: nextStatus)
        }
    }
}

// MARK: - RenderJobPresenting

extension RenderService: RenderJobPresenting {}

// MARK: - PreviewRenderStateReading

extension RenderService: PreviewRenderStateReading {}
#endif
