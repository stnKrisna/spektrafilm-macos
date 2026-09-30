#if os(macOS)
import AppKit
import Foundation
import SpektrafilmCore

/// Deterministic launch hook used only by the SpektrafilmAppUITests target.
///
/// The app is sandboxed (`ENABLE_APP_SANDBOX = YES`), so a UI test cannot hand
/// the app an arbitrary image path to open. Instead, when
/// `SPEKTRAFILM_UI_TEST=1` is present in the environment, the app synthesizes a
/// small, fully deterministic LinearRGB test pattern in-process and loads it
/// exactly as if the user had opened a photograph. This exercises the real
/// preview/profile/render pipeline without touching `NSOpenPanel` or disk.
///
/// The hook is inert in normal launches.
enum UITestSupport {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SPEKTRAFILM_UI_TEST"] == "1"
    }

    /// Builds a small linear-RGB test pattern: a horizontal luminance ramp
    /// overlaid with saturated color patches. Deterministic across runs.
    static func makeTestImage(width: Int = 512, height: Int = 384) -> LinearRGBImage {
        var pixels = [Double](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                // Base: smooth diagonal gradient in scene-linear space.
                let gx = Double(x) / Double(max(width - 1, 1))
                let gy = Double(y) / Double(max(height - 1, 1))
                var r = 0.05 + 0.75 * gx
                var g = 0.05 + 0.75 * gy
                var b = 0.05 + 0.75 * (1 - gx) * (1 - gy)

                // Add a few fully saturated patches for halation/grain/gamut.
                let patch = 96
                if x < patch && y < patch { r = 1.2; g = 0.02; b = 0.02 }          // red
                else if x >= width - patch && y < patch { r = 0.02; g = 1.1; b = 0.02 } // green
                else if x < patch && y >= height - patch { r = 0.02; g = 0.02; b = 1.3 } // blue
                else if x >= width - patch && y >= height - patch { r = 1.0; g = 1.0; b = 1.0 } // white

                pixels[i] = r
                pixels[i + 1] = g
                pixels[i + 2] = b
            }
        }
        return LinearRGBImage(width: width, height: height, pixels: pixels)
    }
}

extension AppViewModel {
    /// Loads the synthetic test image and drives the model to the same state
    /// reached after `openImage()` succeeds. No-op unless UI testing is enabled.
    func bootstrapUITestIfNeeded() {
        guard UITestSupport.isEnabled else { return }
        let env = ProcessInfo.processInfo.environment

        if let live = env["SPEKTRAFILM_UI_TEST_LIVE_PREVIEW"] {
            livePreview = (live == "1")
        }

        let image = UITestSupport.makeTestImage()
        imageService.isRAWSource = false
        imageService.rawAdjustments = .default
        imageService.sourceURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spektrafilm-uitest.tif")
        imageService.sourcePixelSize = CGSize(width: image.width, height: image.height)
        imageService.sourceImage = image
        imageService.sourceImageRevision &+= 1
#if canImport(Metal)
        SpektrafilmPipeline.purgePreviewStageCache()
#endif
        imageService.cachedPreviewSource = image
        imageService.cachedPreviewMaxSize = max(parameters.settings.previewMaxSize, 640)
        viewport.resetForSourceChange()
        imageService.originalPreview = ImageCodec.makeNSImage(image, encodeSRGB: true)
        status = "Loaded spektrafilm-uitest.tif, \(image.width)×\(image.height)."
        previews.sourceDidChange(parameters: parameters)
        requestRender()
    }
}
#endif
