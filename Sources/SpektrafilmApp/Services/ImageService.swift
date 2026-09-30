#if os(macOS)
import AppKit
import Combine
import CoreGraphics
import Foundation
import SpektrafilmCore
import UniformTypeIdentifiers

/// Read-only surface other services depend on instead of reaching into
/// `AppViewModel`.
@MainActor
protocol ImageSourceProviding: AnyObject {
    var sourceImage: LinearRGBImage? { get }
    var sourcePixelSize: CGSize { get }
    var isRAWSource: Bool { get }
    var rawAdjustments: RAWAdjustments { get }
    var sourceImageRevision: UInt { get }
    var sourceURL: URL? { get }
    var originalPreview: NSImage? { get }
    var cachedPreviewSource: LinearRGBImage? { get }
    var cachedPreviewMaxSize: Int { get }
    /// Stores the resized proxy used by the main preview render.
    func storePreviewProxy(_ image: LinearRGBImage, maxSize: Int)
}

/// Which operation failed, so the delegate can present the right message.
enum ImageServiceOperation: Equatable {
    case openingSource
    case adjustingRAW
}

/// UI-side reactions to source loading. `ImageService` owns no status, preview
/// or viewport state itself, which keeps it independently testable.
@MainActor
protocol ImageServiceDelegate: AnyObject {
    /// Long-side limit for the preview proxy from the current render settings.
    func imageServicePreviewMaxSize(_ service: ImageService) -> Int
    /// A new photograph was decoded and installed as the current source.
    func imageServiceDidLoadSource(_ service: ImageService)
    /// A RAW adjustment is about to re-develop the proxy; cancel dependent work.
    func imageServiceWillAdjustRAW(_ service: ImageService)
    /// The RAW proxy finished re-developing after an adjustment.
    func imageServiceDidUpdateRAWProxy(_ service: ImageService)
    func imageService(_ service: ImageService, didFailWith error: Error, operation: ImageServiceOperation)
}

/// Seam over `ImageCodec` proxy decode/render operations. The codec is
/// MainActor-bound (Core Image / AppKit), so the seam is too.
@MainActor
protocol ImageDecoding: AnyObject {
    func rawDefaults(url: URL) -> ImageCodec.RAWDefaults?
    func inspect(url: URL) throws -> ImageCodec.ImageInfo
    func loadRAWLinearSRGB(url: URL, maxDimension: Int, adjustments: RAWAdjustments) throws -> LinearRGBImage
    func loadLinearSRGBThumbnail(url: URL, maxDimension: Int) throws -> LinearRGBImage
    func makeNSImage(_ image: LinearRGBImage, encodeSRGB: Bool) -> NSImage?
}

@MainActor
final class LiveImageDecoder: ImageDecoding {
    func rawDefaults(url: URL) -> ImageCodec.RAWDefaults? { ImageCodec.rawDefaults(url: url) }
    func inspect(url: URL) throws -> ImageCodec.ImageInfo { try ImageCodec.inspect(url: url) }

    func loadRAWLinearSRGB(url: URL, maxDimension: Int, adjustments: RAWAdjustments) throws -> LinearRGBImage {
        try ImageCodec.loadRAWLinearSRGB(url: url, maxDimension: maxDimension, adjustments: adjustments)
    }

    func loadLinearSRGBThumbnail(url: URL, maxDimension: Int) throws -> LinearRGBImage {
        try ImageCodec.loadLinearSRGBThumbnail(url: url, maxDimension: maxDimension)
    }

    func makeNSImage(_ image: LinearRGBImage, encodeSRGB: Bool) -> NSImage? {
        ImageCodec.makeNSImage(image, encodeSRGB: encodeSRGB)
    }
}

/// Seam over process-global pipeline caches.
@MainActor
protocol ImageSourcePlatform: AnyObject {
    func purgePreviewStageCache()
}

@MainActor
final class LiveImageSourcePlatform: ImageSourcePlatform {
    func purgePreviewStageCache() {
        #if canImport(Metal)
        SpektrafilmPipeline.purgePreviewStageCache()
        #endif
    }
}

/// Seam over the image file picker so tests can drive selection without
/// presenting an `NSOpenPanel`.
@MainActor
protocol ImageFilePicking: AnyObject {
    func chooseImageURL() -> URL?
}

@MainActor
final class LiveImageFilePicker: ImageFilePicking {
    func chooseImageURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .rawImage]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Owns the decoded source proxy, its pixel geometry, RAW state and the
/// scene-linear preview proxy. Cross-domain effects (status, preview grids,
/// viewport invalidation, render scheduling) are forwarded to `delegate`.
@MainActor
final class ImageService: ObservableObject, ImageSourceProviding {
    @Published var sourceImage: LinearRGBImage?
    @Published var sourcePixelSize: CGSize = .zero
    @Published var isRAWSource = false
    @Published var rawAdjustments = RAWAdjustments.default
    @Published var originalPreview: NSImage?
    @Published var sourceImageRevision: UInt = 0

    var sourceURL: URL?
    var cachedPreviewSource: LinearRGBImage?
    var cachedPreviewMaxSize: Int = 0

    private var rawRefreshTask: Task<Void, Never>?

    weak var delegate: ImageServiceDelegate?

    private let decoder: ImageDecoding
    private let picker: ImageFilePicking
    private let platform: ImageSourcePlatform

    init(decoder: ImageDecoding = LiveImageDecoder(),
         picker: ImageFilePicking = LiveImageFilePicker(),
         platform: ImageSourcePlatform = LiveImageSourcePlatform()) {
        self.decoder = decoder
        self.picker = picker
        self.platform = platform
    }

    func openImage() {
        guard let url = picker.chooseImageURL() else {
            AppLog.info("app", "Image selection cancelled")
            return
        }
        AppLog.info("app", "Opening image: \(url.path)")
        let start = ContinuousClock.now
        do {
            let proxyMax = delegate?.imageServicePreviewMaxSize(self) ?? 640
            let rawDefaults = decoder.rawDefaults(url: url)
            let info: ImageCodec.ImageInfo
            let image: LinearRGBImage
            if let defaults = rawDefaults {
                isRAWSource = true
                rawAdjustments = defaults.adjustments
                info = defaults.info
                image = try decoder.loadRAWLinearSRGB(url: url, maxDimension: proxyMax, adjustments: rawAdjustments)
                AppLog.info("raw", "Opened RAW source; WB=\(Int(rawAdjustments.temperature))K tint=\(String(format: "%.1f", rawAdjustments.tint)) exposure=\(String(format: "%.2f", rawAdjustments.exposureEV)) EV")
            } else {
                isRAWSource = false
                rawAdjustments = .default
                info = try decoder.inspect(url: url)
                image = try decoder.loadLinearSRGBThumbnail(url: url, maxDimension: proxyMax)
            }
            installSource(image: image, info: info, url: url, proxyMax: proxyMax, started: start)
            delegate?.imageServiceDidLoadSource(self)
        } catch {
            AppLog.error("app", "Image load failed for \(url.path): \(error)")
            delegate?.imageService(self, didFailWith: error, operation: .openingSource)
        }
    }

    func resetRAWAdjustments() {
        guard isRAWSource, let sourceURL, let defaults = decoder.rawDefaults(url: sourceURL) else { return }
        rawAdjustments = defaults.adjustments
    }

    func storePreviewProxy(_ image: LinearRGBImage, maxSize: Int) {
        cachedPreviewSource = image
        cachedPreviewMaxSize = maxSize
    }

    /// Re-develop the RAW proxy after a source-stage RAW adjustment. The
    /// operation is debounced so dragging temperature/tint/exposure controls
    /// does not queue stale demosaic jobs.
    func rawAdjustmentsChanged() {
        guard isRAWSource, let sourceURL else { return }
        delegate?.imageServiceWillAdjustRAW(self)
        rawRefreshTask?.cancel()
        let adjustments = rawAdjustments
        let proxyMax = delegate?.imageServicePreviewMaxSize(self) ?? 640
        rawRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(90))
                try Task.checkCancellation()
                guard let self else { return }
                let started = ContinuousClock.now
                let image = try self.decoder.loadRAWLinearSRGB(url: sourceURL, maxDimension: proxyMax, adjustments: adjustments)
                try Task.checkCancellation()
                self.sourceImage = image
                self.cachedPreviewSource = image
                self.cachedPreviewMaxSize = proxyMax
                self.originalPreview = self.decoder.makeNSImage(image, encodeSRGB: true)
                self.platform.purgePreviewStageCache()
                AppLog.info("raw", "RAW proxy updated in \(AppLog.formatElapsed(AppLog.msSince(started)))")
                self.delegate?.imageServiceDidUpdateRAWProxy(self)
            } catch is CancellationError {
                // Expected while dragging RAW controls.
            } catch {
                AppLog.error("raw", "RAW adjustment failed: \(error)")
                self?.delegate?.imageService(self!, didFailWith: error, operation: .adjustingRAW)
            }
        }
    }

    private func installSource(image: LinearRGBImage, info: ImageCodec.ImageInfo, url: URL, proxyMax: Int, started: ContinuousClock.Instant) {
        sourceURL = url
        sourcePixelSize = CGSize(width: info.width, height: info.height)
        sourceImage = image
        sourceImageRevision &+= 1
        platform.purgePreviewStageCache()
        cachedPreviewSource = image
        cachedPreviewMaxSize = proxyMax
        originalPreview = decoder.makeNSImage(image, encodeSRGB: true)
        let ms = AppLog.msSince(started)
        AppLog.info("app", "Decoded proxy '\(url.lastPathComponent)' \(image.width)×\(image.height) for source \(info.width)×\(info.height) in \(AppLog.formatElapsed(ms))")
    }
}
#endif
