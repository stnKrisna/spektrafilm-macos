#if os(macOS)
import AppKit
import Combine
import Foundation
import SpektrafilmCore

/// Read-only surface for the profile thumbnail grids.
@MainActor
protocol ProfilePreviewProviding: AnyObject {
    var filmPreviewImages: [NSImage?] { get }
    var printPreviewImages: [NSImage?] { get }
    var printPreviewNoneImage: NSImage? { get }
    var isRenderingFilmPreviews: Bool { get }
    var isRenderingPreviews: Bool { get }
}

/// Seam over the thumbnail pipeline so preview orchestration can be tested
/// without Metal or spectral profiles. `nonisolated` so the batches can run
/// from a detached task.
nonisolated protocol PreviewThumbnailRendering: Sendable {
    func render(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters,
        resources: PipelineResources?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> LinearRGBImage
}

nonisolated struct LivePreviewThumbnailRenderer: PreviewThumbnailRendering {
    func render(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters,
        resources: PipelineResources?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> LinearRGBImage {
        try MetalAccelerator.shared.withWorkPriority(.background) {
            try SpektrafilmPipeline.render(
                input: input,
                film: film,
                print: print,
                parameters: parameters,
                resources: resources,
                isCancelled: isCancelled
            ).image
        }
    }
}

/// Owns the film/print thumbnail grids and their one-shot-per-epoch batching.
/// Source and profile data come from their provider protocols; render
/// parameters are supplied per request.
@MainActor
final class ProfilePreviewsService: ObservableObject, ProfilePreviewProviding {
    @Published private(set) var filmPreviewImages: [NSImage?] = []
    @Published private(set) var printPreviewImages: [NSImage?] = []
    @Published private(set) var printPreviewNoneImage: NSImage? = nil
    @Published private(set) var isRenderingFilmPreviews = false
    @Published private(set) var isRenderingPreviews = false

    private var filmPreviewGeneration: UInt = 0
    private var filmPreviewTask: Task<(), Never>?
    private var filmPreviewDebounceTask: Task<Void, Never>?
    /// Bumped whenever the loaded image or profile set changes. Film thumbnails
    /// are a strict one-shot render per epoch; RAW manipulation does not bump it
    /// because the grid is the static "starting point" look of the loaded image.
    private var filmPreviewSourceEpoch: UInt = 0
    private var filmPreviewsGeneratedForEpoch: UInt = 0
    private var filmPreviewBatchEpoch: UInt = 0

    private var printPreviewGeneration: UInt = 0
    private var printPreviewTask: Task<(), Never>?
    private var printPreviewDebounceTask: Task<Void, Never>?
    /// Bumped whenever the loaded image, profile set, or selected film changes.
    private var printPreviewSourceEpoch: UInt = 0
    private var printPreviewsGeneratedForEpoch: UInt = 0
    private var printPreviewBatchEpoch: UInt = 0

    /// True while background thumbnail work is cancelled for an interactive
    /// 100%+ detail inspection.
    private(set) var backgroundPreviewsSuspended = false

    private let profiles: ProfileProviding
    private let images: ImageSourceProviding
    private let renderer: PreviewThumbnailRendering

    init(profiles: ProfileProviding,
         images: ImageSourceProviding,
         renderer: PreviewThumbnailRendering = LivePreviewThumbnailRenderer()) {
        self.profiles = profiles
        self.images = images
        self.renderer = renderer
    }

    /// New source or profile catalog: reset both grids and regenerate them.
    func sourceDidChange(parameters: RenderParameters) {
        printPreviewImages = Array(repeating: nil, count: profiles.printProfiles.count)
        filmPreviewImages = Array(repeating: nil, count: profiles.filmProfiles.count)
        printPreviewNoneImage = nil
        printPreviewSourceEpoch &+= 1
        refreshPrintPreviews(parameters: parameters)
        filmPreviewSourceEpoch &+= 1
        refreshFilmPreviews(parameters: parameters)
    }

    func refreshPrintPreviews(parameters: RenderParameters) {
        guard printPreviewsGeneratedForEpoch != printPreviewSourceEpoch else {
            AppLog.debug("app", "Print preview cache hit; skipping refresh")
            return
        }
        if printPreviewTask != nil, printPreviewBatchEpoch == printPreviewSourceEpoch {
            AppLog.debug("app", "Print preview batch in flight; coalescing")
            return
        }
        printPreviewTask?.cancel()
        printPreviewTask = nil
        printPreviewBatchEpoch = printPreviewSourceEpoch
        guard let input = images.sourceImage, let film = profiles.selectedFilm, !profiles.printProfiles.isEmpty else {
            printPreviewImages = []
            printPreviewNoneImage = nil
            isRenderingPreviews = false
            printPreviewsGeneratedForEpoch = printPreviewSourceEpoch
            return
        }
        printPreviewGeneration &+= 1
        let generation = printPreviewGeneration
        let printProfiles = profiles.printProfiles
        let work = Resample.resize(input, maxDimension: 128)
        var p = parameters
        p.settings.previewMode = true
        let resources = profiles.pipelineResources
        let prewarm = profiles.prewarmTask
        let renderer = self.renderer
        isRenderingPreviews = true
        let paperID = profiles.selectedPrintID ?? "nil"
        let encodeSRGB = !p.io.outputCCTFEncoding
        AppLog.info("app", "Print preview refresh: \(printProfiles.count) profile(s) at \(work.width)×\(work.height), selected=\(paperID)")
        let detached = Task.detached(priority: .utility) { [weak self] in
            if let p = prewarm {
                _ = await p.value
            }
            var results = [LinearRGBImage?](repeating: nil, count: printProfiles.count)
            var noneResult: LinearRGBImage? = nil
            for (index, paper) in printProfiles.enumerated() {
                if Task.isCancelled { break }
                do {
                    results[index] = try renderer.render(input: work, film: film, print: paper, parameters: p, resources: resources, isCancelled: { Task.isCancelled })
                } catch is CancellationError {
                    break
                } catch {
                    AppLog.warning("app", "Print preview failed for '\(paper.id)': \(error)")
                }
            }
            if !Task.isCancelled {
                do {
                    noneResult = try renderer.render(input: work, film: film, print: nil, parameters: p, resources: resources, isCancelled: { Task.isCancelled })
                } catch is CancellationError {
                    // fallthrough: keep thumbnails that were already computed
                } catch {
                    AppLog.warning("app", "Print preview failed for (none): \(error)")
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.printPreviewGeneration == generation else { return }
                self.printPreviewImages = results.map { $0.flatMap { ImageCodec.makeNSImage($0, encodeSRGB: encodeSRGB) } }
                self.printPreviewNoneImage = noneResult.flatMap { ImageCodec.makeNSImage($0, encodeSRGB: encodeSRGB) }
                self.isRenderingPreviews = false
                self.printPreviewTask = nil
                self.printPreviewsGeneratedForEpoch = self.printPreviewSourceEpoch
            }
        }
        printPreviewTask = detached
    }

    func refreshFilmPreviews(parameters: RenderParameters) {
        guard filmPreviewsGeneratedForEpoch != filmPreviewSourceEpoch else {
            AppLog.debug("app", "Film preview cache hit; skipping refresh")
            return
        }
        if filmPreviewTask != nil, filmPreviewBatchEpoch == filmPreviewSourceEpoch {
            AppLog.debug("app", "Film preview batch in flight; coalescing")
            return
        }
        filmPreviewTask?.cancel()
        filmPreviewTask = nil
        filmPreviewBatchEpoch = filmPreviewSourceEpoch
        guard let input = images.sourceImage, !profiles.filmProfiles.isEmpty else {
            filmPreviewImages = []
            isRenderingFilmPreviews = false
            filmPreviewsGeneratedForEpoch = filmPreviewSourceEpoch
            return
        }
        filmPreviewGeneration &+= 1
        let generation = filmPreviewGeneration
        let filmProfiles = profiles.filmProfiles
        let work = Resample.resize(input, maxDimension: 128)
        var p = parameters
        p.settings.previewMode = true
        p.film.grain.active = false
        // Spatial effects (halation, diffusion, lens blur, scanner blur) are
        // sub-pixel at 128px and only add convolutions, so skip them here.
        p.debug.deactivateSpatialEffects = true
        let resources = profiles.pipelineResources
        let prewarm = profiles.prewarmTask
        let renderer = self.renderer
        isRenderingFilmPreviews = true
        let encodeSRGB = !p.io.outputCCTFEncoding
        AppLog.info("app", "Film preview refresh: \(filmProfiles.count) profile(s) at \(work.width)×\(work.height), print=nil, colorPositive=\(p.io.colorPositive)")
        let detached = Task.detached(priority: .utility) { [weak self] in
            if let p = prewarm {
                _ = await p.value
            }
            let warmStart = ContinuousClock.now
            resources?.prewarmTCLUTs(for: filmProfiles)
            AppLog.debug("app", "Film preview TC LUT prewarm: \(AppLog.formatElapsed(AppLog.msSince(warmStart)))")
            var results = [LinearRGBImage?](repeating: nil, count: filmProfiles.count)
            for (index, film) in filmProfiles.enumerated() {
                if Task.isCancelled { break }
                do {
                    results[index] = try renderer.render(input: work, film: film, print: nil, parameters: p, resources: resources, isCancelled: { Task.isCancelled })
                } catch is CancellationError {
                    break
                } catch {
                    AppLog.warning("app", "Film preview failed for '\(film.id)': \(error)")
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.filmPreviewGeneration == generation else { return }
                self.filmPreviewImages = results.map { $0.flatMap { ImageCodec.makeNSImage($0, encodeSRGB: encodeSRGB) } }
                self.isRenderingFilmPreviews = false
                self.filmPreviewTask = nil
                self.filmPreviewsGeneratedForEpoch = self.filmPreviewSourceEpoch
            }
        }
        filmPreviewTask = detached
    }

    /// Applies editor changes to the profile browsers only from the parameter
    /// categories that affect them. Source & Camera drives the negative
    /// "starting point" look of both grids; Film/Enlarger/Print chemistry
    /// refreshes only the print grid; Scanner & Output refreshes neither.
    func scheduleProfilePreviewRefreshes(film: Bool, print: Bool, parameters: RenderParameters) {
        guard images.sourceImage != nil else { return }

        if film {
            filmPreviewSourceEpoch &+= 1
            filmPreviewGeneration &+= 1
            filmPreviewTask?.cancel()
            filmPreviewTask = nil
            isRenderingFilmPreviews = false
            filmPreviewDebounceTask?.cancel()
            let epoch = filmPreviewSourceEpoch
            filmPreviewDebounceTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !Task.isCancelled, self.filmPreviewSourceEpoch == epoch else { return }
                self.filmPreviewDebounceTask = nil
                AppLog.debug("app", "Film profile preview debounce elapsed (1 s); refreshing epoch=\(epoch)")
                self.refreshFilmPreviews(parameters: parameters)
            }
        }

        if print {
            printPreviewSourceEpoch &+= 1
            printPreviewGeneration &+= 1
            printPreviewTask?.cancel()
            printPreviewTask = nil
            isRenderingPreviews = false
            printPreviewDebounceTask?.cancel()
            let epoch = printPreviewSourceEpoch
            printPreviewDebounceTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !Task.isCancelled, self.printPreviewSourceEpoch == epoch else { return }
                self.printPreviewDebounceTask = nil
                AppLog.debug("app", "Print profile preview debounce elapsed (5 s); refreshing epoch=\(epoch)")
                self.refreshPrintPreviews(parameters: parameters)
            }
        }
    }

    func suspendBackgroundPreviews() {
        backgroundPreviewsSuspended = true
        printPreviewTask?.cancel(); printPreviewTask = nil
        filmPreviewTask?.cancel(); filmPreviewTask = nil
        printPreviewGeneration &+= 1
        filmPreviewGeneration &+= 1
        isRenderingPreviews = false
        isRenderingFilmPreviews = false
    }

    /// Resumes suspended grids for any epoch whose published images are stale.
    func resumeBackgroundPreviewsIfNeeded(parameters: RenderParameters) {
        guard backgroundPreviewsSuspended else { return }
        backgroundPreviewsSuspended = false
        if printPreviewsGeneratedForEpoch != printPreviewSourceEpoch { refreshPrintPreviews(parameters: parameters) }
        if filmPreviewsGeneratedForEpoch != filmPreviewSourceEpoch { refreshFilmPreviews(parameters: parameters) }
    }
}

// MARK: - BackgroundPreviewCoordinating

extension ProfilePreviewsService: BackgroundPreviewCoordinating {}
#endif
