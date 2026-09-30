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

/// Render-related coordination that spans services. Actual render execution
/// lives in `RenderService` and profile-preview batching in
/// `ProfilePreviewsService`; these wrappers apply the `livePreview` gate and
/// feed the current parameters.
extension AppViewModel {
    func requestRender() {
        guard livePreview else {
            AppLog.debug("app", "Render skipped (live preview off)")
            return
        }
        renderImmediately()
    }

    func requestDebouncedRender() {
        guard livePreview else { return }
        renderService.requestDebouncedRender(parameters: parameters)
    }

    /// Explicit/discrete render actions bypass the interactive debounce.
    func renderImmediately() {
        renderService.renderImmediately(parameters: parameters)
    }

    /// Apply editor changes to the main preview immediately, then refresh the
    /// profile browsers only from the parameter categories that affect them.
    /// Source & Camera drives the negative "starting point" look of both picker
    /// grids; Film/Enlarger/Print chemistry refreshes only the print grid
    /// (the paper look depends on the negative); Scanner & Output never
    /// refreshes the pickers.
    func parametersChanged(from old: RenderParameters, to new: RenderParameters) {
        requestDebouncedRender()
        let cameraChanged = old.camera != new.camera
        let scannerOrOutputChanged = old.scanner != new.scanner || old.io != new.io
        let chemistryChanged = old.film != new.film || old.enlarger != new.enlarger || old.print != new.print
        if cameraChanged {
            previews.scheduleProfilePreviewRefreshes(film: true, print: true, parameters: parameters)
        } else if scannerOrOutputChanged {
            // Scanner & Output: no profile-picker refresh.
        } else if chemistryChanged {
            previews.scheduleProfilePreviewRefreshes(film: false, print: true, parameters: parameters)
        }
    }

    func selectedFilmChanged() {
        requestRender()
        // Candidate film thumbnails do not depend on which film is selected.
        // Print thumbnails do: they render each paper from the selected film.
        previews.scheduleProfilePreviewRefreshes(film: false, print: true, parameters: parameters)
    }
}
#endif
