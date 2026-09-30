#if os(macOS)
import AppKit
import Combine
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import SpektrafilmCore
import SpektrafilmPreviewGeometry
import UniformTypeIdentifiers
@MainActor
final class AppViewModel: ObservableObject {
    let profiles: ProfileService
    let imageService: ImageService
    let renderService: RenderService
    let previews: ProfilePreviewsService
    let exportService: ExportService
    let viewport: ViewportService

    init(services: ServiceProvider = ServiceProvider()) {
        self.profiles = services.profiles
        self.imageService = services.imageService
        self.renderService = services.renderService
        self.previews = services.previews
        self.exportService = services.exportService
        self.viewport = services.viewport
        self.profiles.delegate = self
        self.imageService.delegate = self
        self.renderService.delegate = self
        self.exportService.delegate = self
        self.profiles.loadBundledProfiles()
    }

    @Published var parameters = RenderParameters()
    @Published var status = "Open an image, then choose a profile directory."
    @Published var showOriginal = false
    @Published var livePreview = true
}

// MARK: - ProfileServiceDelegate

extension AppViewModel: ProfileServiceDelegate {
    func profileService(_ service: ProfileService, didLoadProfiles totalCount: Int) {
        previews.sourceDidChange(parameters: parameters)
        status = "Loaded \(totalCount) profiles."
        requestRender()
    }

    func profileService(_ service: ProfileService, didFailWith error: Error) {
        status = "Profile load failed: \(error.localizedDescription)"
    }

    func profileServiceDidFindNoBundledProfiles(_ service: ProfileService) {
        status = "No bundled profiles found. Choose a profile directory."
    }
}

// MARK: - ImageServiceDelegate

extension AppViewModel: ImageServiceDelegate {
    func imageServicePreviewMaxSize(_ service: ImageService) -> Int {
        max(parameters.settings.previewMaxSize, 640)
    }

    func imageServiceDidLoadSource(_ service: ImageService) {
        if service.isRAWSource {
            // CIRAWFilter is rendered into extended linear sRGB; keep the
            // simulation's input interpretation aligned with that source.
            parameters.io.inputColorSpace = "sRGB"
            parameters.io.inputCCTFDecoding = false
        }
        viewport.resetForSourceChange()
        previews.sourceDidChange(parameters: parameters)
        if let url = service.sourceURL {
            status = "Loaded \(url.lastPathComponent), \(Int(service.sourcePixelSize.width))×\(Int(service.sourcePixelSize.height))."
        }
        requestRender()
    }

    func imageServiceWillAdjustRAW(_ service: ImageService) {
        previews.scheduleProfilePreviewRefreshes(film: true, print: true, parameters: parameters)
        viewport.sourceDidChange()
    }

    func imageServiceDidUpdateRAWProxy(_ service: ImageService) {
        viewport.resetForSourceChange()
        requestDebouncedRender()
    }

    func imageService(_ service: ImageService, didFailWith error: Error, operation: ImageServiceOperation) {
        switch operation {
        case .openingSource:
            status = "Image load failed: \(error.localizedDescription)"
        case .adjustingRAW:
            status = "RAW adjustment failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - RenderServiceDelegate

extension AppViewModel: RenderServiceDelegate {
    func renderService(_ service: RenderService, didUpdateStatus status: String) {
        self.status = status
    }

    func renderServiceWillBeginRender(_ service: RenderService) {
        viewport.invalidateDetailTiles()
    }

    func renderServiceDidCompleteRender(_ service: RenderService) {
        // Give the primary photo preview first use of CPU/GPU resources.
        // Re-request the last viewport so the new chemistry is reflected in the ROI.
        if let geometry = viewport.lastViewportGeometry {
            viewport.requestViewportPreview(geometry, rendered: viewport.lastViewportRendered, parameters: parameters)
        }
    }
}

// MARK: - ExportServiceDelegate

extension AppViewModel: ExportServiceDelegate {
    func exportService(_ service: ExportService, didUpdateStatus status: String) {
        self.status = status
    }
}
#endif
