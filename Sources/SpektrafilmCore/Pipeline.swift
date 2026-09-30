import Foundation
#if canImport(Metal)
import Metal
#endif

public enum PipelineStage: String, Sendable, CaseIterable {
    case input, filming, negative, printing, paper, scanning, output
}

/// Fine-grained numerical tap points used by regression/parity tests.
/// These names intentionally mirror the Python reference implementation's
/// tap vocabulary where practical.
public enum PipelineTap: String, Sendable, CaseIterable {
    case filmRaw
    case filmLogExposure
    case negativeDensity
    case printExposure
    case printDensity
    case scannerLinearRGB
}

public struct RenderResult: Sendable {
    public let image: LinearRGBImage
    public let autoExposureEV: Double
    public let stage: PipelineStage

    public init(image: LinearRGBImage, autoExposureEV: Double, stage: PipelineStage) {
        self.image = image
        self.autoExposureEV = autoExposureEV
        self.stage = stage
    }
}

public enum SpektrafilmPipeline {
    /// Native Swift CPU pipeline. It follows the same stage boundaries as the Rust port:
    /// filming → printing → scanning. Spectral RGB→raw upsampling is deliberately isolated
    /// as the next parity milestone; this implementation uses RGB channel exposure as its
    /// current fallback rather than pretending to be Hanatos2025-equivalent.
    public static func render(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters = .init(),
        resources: PipelineResources? = nil,
        stopAfter: PipelineStage = .output,
        progress: @escaping (Double, String) -> Void = { _, _ in },
        isCancelled: @escaping () -> Bool = { false },
        tap: @escaping (PipelineTap, LinearRGBImage) -> Void = { _, _ in },
        sourceLongSideOverride: Int? = nil,
        autoExposureEVOverride: Double? = nil
    ) throws -> RenderResult {
        let start = ContinuousClock.now
        AppLog.debug("pipeline", "render(input: \(input.width)×\(input.height), film: '\(film.id)', print: '\(print?.id ?? "nil")', stopAfter: \(stopAfter.rawValue))")
        func emit(_ fraction: Double, _ label: String) { progress(min(max(fraction, 0), 1), label) }
        func tick() throws { if isCancelled() { throw CancellationError() } }
        try tick()
        emit(0, "Preparing")
        let wantsMetal = parameters.settings.previewMode ? parameters.settings.useMetalPreview : parameters.settings.useMetalExport
        let useGPU = wantsMetal && MetalAccelerator.shared.isAvailable
        let metalMode = parameters.settings.previewMode ? "preview" : "export"
        AppLog.info("pipeline", "math backend=\(useGPU ? "Metal f32 \(metalMode)" : "CPU f64")")

        var image = input
        let originalLongSide = sourceLongSideOverride ?? max(input.width, input.height)
        let basePixelSize = parameters.camera.filmFormatMillimeters * 1000 / Double(max(originalLongSide, 1))
        let autoEV = autoExposureEVOverride ?? (parameters.camera.autoExposure ? autoExposureEV(image, method: parameters.camera.autoExposureMethod) : 0)
        let autoScale = pow(2, autoEV)
        AppLog.debug("pipeline", "auto exposure EV=\(String(format: "%.3f", autoEV)), exposure compensation=\(String(format: "%.3f", parameters.camera.exposureCompensationEV))")
        if parameters.io.crop {
            image = Resample.cropNormalized(image, center: parameters.io.cropCenter, size: parameters.io.cropSize)
        }
        if abs(parameters.io.upscale - 1) > 1e-12 {
            image = Resample.bicubicRescale(image, factor: max(parameters.io.upscale, 1e-6))
        }
        emit(0.02, "Exposure / resize")
        if stopAfter == .input {
            image.mapInPlace { max($0 * autoScale, 1e-10) }
            AppLog.debug("pipeline", "stopped after input stage")
            return .init(image: image, autoExposureEV: autoEV, stage: .input)
        }

        try tick()
        let pixelSize = basePixelSize / max(parameters.io.upscale, 1e-12)
        AppLog.debug("pipeline", "film format=\(parameters.camera.filmFormatMillimeters) mm, pixel size=\(String(format: "%.3f", pixelSize)) µm")

#if canImport(Metal)
        // Fast preview path starts at source RGB. Auto/camera exposure, spectral RGB→film raw,
        // highlight reconstruction and camera spatial effects remain in the same resident batch
        // as film/print/scan. Input xy-gamut compression is still a reference-path fallback.
        if useGPU, parameters.settings.previewMode, stopAfter == .output, !parameters.scanFilm,
           let print, let resources, !parameters.io.inputGamutCompression.active,
           !parameters.enlarger.diffusionFilter.active, !parameters.print.densityCurvesMorph.active,
           let resident = tryResidentPreviewCore(
                inputRGB: image, exposureScale: autoScale, film: film, print: print, parameters: parameters, resources: resources,
                pixelSize: pixelSize, spatialOff: parameters.debug.deactivateSpatialEffects || parameters.debug.lutMode, isCancelled: isCancelled
           ) {
            emit(1, "Done")
            AppLog.debug("pipeline", "render done via GPU-resident RGB→film→DIR→grain→print→scan→CAM16→scanner core; one final image readback")
            return .init(image: resident, autoExposureEV: autoEV, stage: .output)
        }
#endif

        // Reference/fallback path. Apply source exposure on CPU only when the resident graph cannot handle the request.
        image.mapInPlace { max($0 * autoScale, 1e-10) }

        // Python order: RGB→film raw, highlight reconstruction, camera lens/spatial effects, halation.
        var filmRaw = resources.map { SpectralService.rgbToFilmRaw(image, profile: film, resources: $0, camera: parameters.camera, inputColorSpace: parameters.io.inputColorSpace, inputGamutCompression: parameters.io.inputGamutCompression, useGPU: useGPU) } ?? image
        let cameraExposureScale = pow(2, parameters.camera.exposureCompensationEV)
        filmRaw.mapInPlace { max($0 * cameraExposureScale, 1e-30) }
        filmRaw = FilmModels.boostHighlights(
            filmRaw,
            boostEV: parameters.film.halation.boostEV,
            boostRange: parameters.film.halation.boostRange,
            protectEV: parameters.film.halation.protectEV
        )
        let spatialOff = parameters.debug.deactivateSpatialEffects || parameters.debug.lutMode
        if !spatialOff && parameters.camera.diffusionFilter.active {
            filmRaw = DiffusionFilterModel.apply(filmRaw, parameters: parameters.camera.diffusionFilter, pixelSizeMicrometers: pixelSize, useGPU: useGPU)
        }
        if !spatialOff && parameters.camera.lensBlurMicrometers > 0 {
            filmRaw = Convolution.gaussianBlur(filmRaw, sigma: parameters.camera.lensBlurMicrometers / max(pixelSize, 0.1), useGPU: useGPU)
        }
        var halationParameters = parameters.film.halation
        if spatialOff { halationParameters.active = false }
        filmRaw = try FilmModels.applyHalation(
            filmRaw,
            params: halationParameters,
            pixelSizeMicrometers: pixelSize,
            useGPU: useGPU,
            halationProgress: { hf in emit(0.05 + 0.23 * hf, "Halation") },
            cancelled: isCancelled
        )
        tap(.filmRaw, filmRaw)
        emit(0.30, "Filming")
        if stopAfter == .filming { return .init(image: filmRaw, autoExposureEV: autoEV, stage: .filming) }


        try tick()
        var logRaw = filmRaw.mapped { log10(max($0, 0) + 1e-10) }
        tap(.filmLogExposure, logRaw)
        var negative = FilmModels.develop(logExposure: logRaw, profile: film, gamma: parameters.film.densityCurveGamma, useGPU: useGPU)
        AppLog.debug("pipeline", "develop: density curve gamma=\(parameters.film.densityCurveGamma)")
        emit(0.52, "Develop")
        try tick()
        negative = FilmModels.applyDIR(negative, logRaw: logRaw, profile: film, params: parameters.film.dirCouplers, pixelSizeMicrometers: pixelSize, gamma: parameters.film.densityCurveGamma, useGPU: useGPU)
        AppLog.debug("pipeline", "DIR couplers applied: active=\(parameters.film.dirCouplers.active), amount=\(parameters.film.dirCouplers.amount)")
        emit(0.57, "DIR couplers")
        try tick()
        var grainParameters = parameters.film.grain
        if parameters.debug.deactivateStochasticEffects || parameters.debug.lutMode { grainParameters.active = false }
        negative = FilmModels.applyGrain(negative, params: grainParameters, profile: film, pixelSizeMicrometers: pixelSize, useGPU: useGPU)
        tap(.negativeDensity, negative)
        AppLog.debug("pipeline", "grain applied: active=\(parameters.film.grain.active), seed=\(parameters.film.grain.seed)")
        emit(0.62, "Grain")
        if stopAfter == .negative || parameters.scanFilm || print == nil {
            AppLog.debug("pipeline", parameters.scanFilm ? "scan film directly (scanFilm=true)" : print == nil ? "no print profile; scanning negative" : "stopped after negative stage")
            var scanned = scanDensity(negative, profile: film, resources: resources, parameters: parameters.scanner, io: parameters.io, spatialOff: spatialOff, glare: nil, useGPU: useGPU)
            if parameters.io.colorPositive { scanned = invertToColorPositive(scanned) }
            emit(1, "Done")
            return .init(image: scanned, autoExposureEV: autoEV, stage: stopAfter == .negative ? .negative : .output)
        }

        guard let print else {
            AppLog.warning("pipeline", "print profile was nil after negative stage; scanning negative directly")
            var scanned = scanDensity(negative, profile: film, resources: resources, parameters: parameters.scanner, io: parameters.io, spatialOff: spatialOff, glare: nil, useGPU: useGPU)
            if parameters.io.colorPositive { scanned = invertToColorPositive(scanned) }
            return .init(image: scanned, autoExposureEV: autoEV, stage: .output)
        }
        try tick()
        var enlarger = parameters.enlarger
        if parameters.settings.neutralPrintFiltersFromDatabase,
           let resources,
           let filters = resources.pack.neutralPrintFilters[print.id]?[enlarger.illuminant]?[film.id],
           filters.count >= 3 {
            enlarger.cFilterNeutral = filters[0]
            enlarger.mFilterNeutral = filters[1]
            enlarger.yFilterNeutral = filters[2]
            AppLog.debug("pipeline", "neutral print filters from database: C=\(filters[0]), M=\(filters[1]), Y=\(filters[2])")
        }
        var printExposure = resources.flatMap { SpectralService.printExposure(negative, film: film, print: print, resources: $0, parameters: enlarger, camera: parameters.camera, filmRendering: parameters.film, inputColorSpace: parameters.io.inputColorSpace, useGPU: useGPU) }
            ?? densityToPrintExposure(negative, params: enlarger)
        AppLog.debug("pipeline", "print exposure computed: printExposure=\(String(format: "%.3f", enlarger.printExposure)), yShift=\(enlarger.yFilterShift), mShift=\(enlarger.mFilterShift), preflash=\(enlarger.preflashExposure), normalize=\(enlarger.normalizePrintExposure)")
        tap(.printExposure, printExposure)
        emit(0.77, "Print exposure")
        if !spatialOff && parameters.enlarger.diffusionFilter.active {
            printExposure = DiffusionFilterModel.apply(printExposure, parameters: parameters.enlarger.diffusionFilter, pixelSizeMicrometers: pixelSize, useGPU: useGPU)
        }
        if !spatialOff && parameters.enlarger.lensBlur > 0 { printExposure = Convolution.gaussianBlur(printExposure, sigma: parameters.enlarger.lensBlur, useGPU: useGPU) }
        if stopAfter == .printing { AppLog.debug("pipeline", "stopped after printing stage"); return .init(image: printExposure, autoExposureEV: autoEV, stage: .printing) }

        try tick()
        // Rust/Python intentionally do a log around the normalized print exposure before
        // interpolating print density curves. Keep epsilon explicit for deterministic math.
        logRaw = printExposure.mapped { log10(max($0, 0) + 1e-10) }
        let paper = FilmModels.developPrintMorph(logExposure: logRaw, profile: print, parameters: parameters.print.densityCurvesMorph)
        tap(.printDensity, paper)
        AppLog.debug("pipeline", "paper developed from '\(print.id)' with gamma=1.0")
        emit(0.87, "Paper")
        if stopAfter == .paper { AppLog.debug("pipeline", "stopped after paper stage"); return .init(image: paper, autoExposureEV: autoEV, stage: .paper) }

        try tick()
        let scanned = scanDensity(paper, profile: print, resources: resources, parameters: parameters.scanner, io: parameters.io, spatialOff: spatialOff, glare: parameters.debug.deactivateStochasticEffects || parameters.debug.lutMode ? nil : parameters.print.glare, useGPU: useGPU)
        tap(.scannerLinearRGB, scanned)
        AppLog.debug("pipeline", "scanned paper: lensBlur=\(parameters.scanner.lensBlur), unsharp=\(parameters.scanner.unsharpAmount), white/black correction=\(parameters.scanner.whiteCorrection)/\(parameters.scanner.blackCorrection)")
        emit(1, "Done")
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        AppLog.debug("pipeline", "render done: stage=\(stopAfter.rawValue), \(formatElapsed(ms)), output finite=\(scanned.allFinite())")
        return .init(image: scanned, autoExposureEV: autoEV, stage: .output)
    }

    private static func formatElapsed(_ milliseconds: Double) -> String {
        if milliseconds >= 1000 { return String(format: "%.2f s", milliseconds / 1000) }
        return String(format: "%.0f ms", milliseconds)
    }

    public static func autoExposureEV(_ image: LinearRGBImage, method: String = "center_weighted") -> Double {
        var weighted = 0.0
        var weights = 0.0
        let cx = Double(image.width - 1) / 2
        let cy = Double(image.height - 1) / 2
        let sx = max(Double(image.width) * 0.35, 1)
        let sy = max(Double(image.height) * 0.35, 1)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let l = max(1e-8, 0.2126 * image[x,y,0] + 0.7152 * image[x,y,1] + 0.0722 * image[x,y,2])
                let w: Double
                switch method {
                case "average": w = 1
                default:
                    let dx = (Double(x) - cx) / sx
                    let dy = (Double(y) - cy) / sy
                    w = exp(-0.5 * (dx * dx + dy * dy))
                }
                weighted += l * w
                weights += w
            }
        }
        let metered = weighted / max(weights, 1e-12)
        return -log2(max(metered, 1e-12) / 0.184)
    }

    private static func densityToPrintExposure(_ density: LinearRGBImage, params: EnlargerParameters) -> LinearRGBImage {
        let start = ContinuousClock.now
        var out = LinearRGBImage(width: density.width, height: density.height)
        let y = pow(2, params.yFilterShift / 30)
        let m = pow(2, params.mFilterShift / 30)
        let filters = [1.0 / max(y, 1e-6), 1.0 / max(m, 1e-6), sqrt(y * m)]
        for yy in 0..<density.height {
            for x in 0..<density.width {
                for c in 0..<3 {
                    let transmitted = pow(10, -max(density[x,yy,c], 0))
                    out[x,yy,c] = transmitted * params.printExposure * filters[c] + params.preflashExposure
                }
            }
        }
        if params.normalizePrintExposure {
            var logs = [Double]()
            logs.reserveCapacity(out.width * out.height)
            for yy in 0..<out.height {
                for x in 0..<out.width {
                    let v = (out[x,yy,0] + out[x,yy,1] + out[x,yy,2]) / 3
                    logs.append(log(max(v, 1e-12)))
                }
            }
            let geo = exp(logs.reduce(0,+) / Double(max(logs.count, 1)))
            let factor = 0.184 / max(geo, 1e-12)
            out.mapInPlace { $0 * factor }
        }
        AppLog.debug("pipeline", "densityToPrintExposure done: \(AppLog.formatElapsed(AppLog.msSince(start)))")
        return out
    }


#if canImport(Metal)
    public struct PreviewTextureResult: @unchecked Sendable {
        public let texture: MTLTexture
        public let autoExposureEV: Double
        public let width: Int
        public let height: Int
    }

    /// Identity of an interactive ROI render. It deliberately excludes edit parameters:
    /// stage-specific keys append only the parameters that affect that stage, allowing
    /// late-stage edits to reuse upstream resident Metal buffers.
    public struct PreviewCacheContext: Sendable, Hashable {
        public let sourceRevision: UInt64
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        /// Quantized render scale in thousandths (250 = 0.25x).
        public let scaleMilli: Int
        public let sourceWidth: Int
        public init(sourceRevision: UInt64, x: Int, y: Int, width: Int, height: Int, scale: Double, sourceWidth: Int) {
            self.sourceRevision = sourceRevision; self.x = x; self.y = y; self.width = width; self.height = height
            self.scaleMilli = Int((scale * 1000).rounded()); self.sourceWidth = sourceWidth
        }
        fileprivate var baseKey: String { "\(sourceRevision):\(x),\(y),\(width)x\(height):s\(scaleMilli)" }
    }

    private final class ResidentStageCache: @unchecked Sendable {
        static let shared = ResidentStageCache()
        private let lock = NSLock()
        private var values: [String: MetalAccelerator.ResidentImage] = [:]
        private var lru: [String] = []
        private let limit = 24
        func get(_ key: String) -> MetalAccelerator.ResidentImage? {
            lock.lock(); defer { lock.unlock() }
            guard let value = values[key] else { return nil }
            lru.removeAll { $0 == key }; lru.append(key); return value
        }
        func put(_ value: MetalAccelerator.ResidentImage, key: String) {
            lock.lock(); defer { lock.unlock() }
            values[key] = value; lru.removeAll { $0 == key }; lru.append(key)
            while lru.count > limit, let evict = lru.first { lru.removeFirst(); values.removeValue(forKey: evict) }
        }
        func purge() { lock.lock(); values.removeAll(keepingCapacity: false); lru.removeAll(keepingCapacity: false); lock.unlock() }
    }

    /// Drop ROI stage buffers after opening a new source or under memory pressure.
    public static func purgePreviewStageCache() { ResidentStageCache.shared.purge() }

    private static func previewFingerprint(_ value: Any) -> String { String(reflecting: value) }

    /// Preview-only texture endpoint used by the 1:1 canvas. The final resident
    /// float4 image is copied directly to an MTLTexture; no LinearRGBImage/NSImage
    /// is constructed on the successful path.
    public static func renderPreviewTexture(
        input: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile?,
        parameters: RenderParameters,
        resources: PipelineResources?,
        sourceLongSideOverride: Int? = nil,
        autoExposureEVOverride: Double? = nil,
        cropX: Int = 0, cropY: Int = 0, cropWidth: Int? = nil, cropHeight: Int? = nil,
        renderScale: Double = 1,
        cacheContext: PreviewCacheContext? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) -> PreviewTextureResult? {
        guard parameters.settings.previewMode, parameters.settings.useMetalPreview,
              MetalAccelerator.shared.isAvailable, !parameters.scanFilm,
              let print, let resources, !parameters.io.inputGamutCompression.active,
              !parameters.enlarger.diffusionFilter.active, !parameters.print.densityCurvesMorph.active else { return nil }
        var image = input
        let originalLongSide = sourceLongSideOverride ?? max(input.width, input.height)
        let basePixelSize = parameters.camera.filmFormatMillimeters * 1000 / Double(max(originalLongSide, 1))
        let autoEV = autoExposureEVOverride ?? (parameters.camera.autoExposure ? autoExposureEV(image, method: parameters.camera.autoExposureMethod) : 0)
        if parameters.io.crop { image = Resample.cropNormalized(image, center: parameters.io.cropCenter, size: parameters.io.cropSize) }
        if abs(parameters.io.upscale - 1) > 1e-12 { image = Resample.bicubicRescale(image, factor: max(parameters.io.upscale, 1e-6)) }
        // Spatial effects are specified in physical units. A reduced-resolution ROI has
        // larger micrometers-per-render-pixel, so scale radii down with the render.
        let pixelSize = basePixelSize / max(parameters.io.upscale * max(renderScale, 0.01), 1e-12)
        let spatialOff = parameters.debug.deactivateSpatialEffects || parameters.debug.lutMode
        guard !isCancelled(), let resident = tryResidentPreviewResident(inputRGB: image, exposureScale: pow(2, autoEV), film: film, print: print, parameters: parameters, resources: resources, pixelSize: pixelSize, spatialOff: spatialOff, cacheContext: cacheContext, renderScale: renderScale, isCancelled: isCancelled),
              let texture = MetalAccelerator.shared.textureResident(resident, cropX: cropX, cropY: cropY, cropWidth: cropWidth, cropHeight: cropHeight) else { return nil }
        return PreviewTextureResult(texture: texture, autoExposureEV: autoEV, width: texture.width, height: texture.height)
    }

    private static func tryResidentPreviewCore(
        inputRGB: LinearRGBImage,
        exposureScale: Double,
        film: FilmProfile,
        print: FilmProfile,
        parameters: RenderParameters,
        resources: PipelineResources,
        pixelSize: Double,
        spatialOff: Bool,
        isCancelled: () -> Bool
    ) -> LinearRGBImage? {
        let start = ContinuousClock.now
        guard let finalResident = tryResidentPreviewResident(inputRGB: inputRGB, exposureScale: exposureScale, film: film, print: print, parameters: parameters, resources: resources, pixelSize: pixelSize, spatialOff: spatialOff, cacheContext: nil, renderScale: 1, isCancelled: isCancelled) else { return nil }
        let scanned = MetalAccelerator.shared.downloadResident(finalResident)
        AppLog.info("metal", "GPU-resident single-command-buffer RGB→film→DIR→grain→print→scan→CAM16→scanner core: \(AppLog.formatElapsed(AppLog.msSince(start))); commandBuffers=1 imageReadbacks=1")
        return scanned
    }

    private static func tryResidentPreviewResident(
        inputRGB: LinearRGBImage,
        exposureScale: Double,
        film: FilmProfile,
        print: FilmProfile,
        parameters: RenderParameters,
        resources: PipelineResources,
        pixelSize: Double,
        spatialOff: Bool,
        cacheContext: PreviewCacheContext?,
        renderScale: Double,
        isCancelled: () -> Bool
    ) -> MetalAccelerator.ResidentImage? {
        if isCancelled() { return nil }
        let cache = ResidentStageCache.shared
        let base = cacheContext?.baseKey
        let cameraKey = base.map { $0 + ":camera:" + film.id + ":" + previewFingerprint(parameters.camera) + ":" + previewFingerprint(parameters.film.halation) + ":" + parameters.io.inputColorSpace + ":sp=" + String(spatialOff) }
        let filmKey = cameraKey.map { $0 + ":film:" + String(parameters.film.densityCurveGamma) + ":" + previewFingerprint(parameters.film.dirCouplers) }
        let grainKey = filmKey.map { $0 + ":grain:" + previewFingerprint(parameters.film.grain) + ":stochOff=" + String(parameters.debug.deactivateStochasticEffects || parameters.debug.lutMode) }
        let printKey = grainKey.map { $0 + ":print:" + print.id + ":" + previewFingerprint(parameters.enlarger) }
        let scanKey = printKey.map { $0 + ":scan:" + parameters.io.outputColorSpace + ":" + previewFingerprint(parameters.io.outputGamutCompression) + ":" + previewFingerprint(parameters.print.glare) }

        return MetalAccelerator.shared.withResidentBatch {
            if isCancelled() { return nil }
            var cleanNegative: MetalAccelerator.ResidentImage
            if let filmKey, let cached = cache.get(filmKey) {
                cleanNegative = cached
                AppLog.debug("preview-cache", "film-stage hit \(filmKey)")
            } else {
                guard let source = MetalAccelerator.shared.uploadResident(inputRGB) else { return nil }
                let target = resources.pack.xyzWhite(for: film.info.referenceIlluminant)
                let sourceSpace = ColorScience.rgbSpace(parameters.io.inputColorSpace)
                let adapt = ColorScience.adaptationCAT16(src: sourceSpace.white, dst: target)
                let filtered = SpectralService.filteredCameraSensitivity(profile: film, resources: resources, uv: parameters.camera.filterUV, ir: parameters.camera.filterIR)
                let suffix = filtered.didFilter ? "uv=\(parameters.camera.filterUV);ir=\(parameters.camera.filterIR)" : ""
                let lut = resources.tcLUT(for: film, sensitivityOverride: filtered.didFilter ? filtered.sensitivity : nil, cacheSuffix: suffix)
                guard var raw = MetalAccelerator.shared.rgbToFilmRawResident(source, lut: lut, sourceToXYZ: sourceSpace.toXYZ, adaptation: adapt, cacheKey: "\(film.id):\(suffix)"),
                      let exposed = MetalAccelerator.shared.scaleResident(raw, scale: exposureScale * pow(2, parameters.camera.exposureCompensationEV)) else { return nil }
                raw = exposed
                if parameters.film.halation.boostEV > 0 {
                    guard let boosted = MetalAccelerator.shared.boostHighlightsResident(raw, boostEV: parameters.film.halation.boostEV, boostRange: parameters.film.halation.boostRange, protectEV: parameters.film.halation.protectEV) else { return nil }
                    raw = boosted
                }
                if !spatialOff && parameters.camera.diffusionFilter.active {
                    guard let diffused = DiffusionFilterModel.applyResident(raw, parameters: parameters.camera.diffusionFilter, pixelSizeMicrometers: pixelSize) else { return nil }; raw = diffused
                }
                if !spatialOff && parameters.camera.lensBlurMicrometers > 0 {
                    guard let blurred = MetalAccelerator.shared.gaussianBlurResident(raw, sigmas: Array(repeating: parameters.camera.lensBlurMicrometers / max(pixelSize, 0.1), count: 3)) else { return nil }; raw = blurred
                }
                var halation = parameters.film.halation; if spatialOff { halation.active = false }
                guard let halated = FilmModels.applyHalationResident(raw, params: halation, pixelSizeMicrometers: pixelSize),
                      let logRaw = MetalAccelerator.shared.log10Resident(halated),
                      var negative = FilmModels.developResident(logRaw, profile: film, gamma: parameters.film.densityCurveGamma),
                      let dir = FilmModels.applyDIRResident(negative, logRaw: logRaw, profile: film, params: parameters.film.dirCouplers, pixelSizeMicrometers: pixelSize, gamma: parameters.film.densityCurveGamma) else { return nil }
                negative = dir; cleanNegative = negative
                if let filmKey { cache.put(cleanNegative, key: filmKey) }
            }
            if isCancelled() { return nil }

            var negative: MetalAccelerator.ResidentImage
            if let grainKey, let cached = cache.get(grainKey) { negative = cached }
            else {
                var grainParams = parameters.film.grain
                if parameters.debug.deactivateStochasticEffects || parameters.debug.lutMode { grainParams.active = false }
                let grainOrigin = SIMD2<UInt32>(UInt32(max(cacheContext?.x ?? 0, 0)), UInt32(max(cacheContext?.y ?? 0, 0)))
                let sourceWidth = UInt32(max(cacheContext?.sourceWidth ?? inputRGB.width, 1))
                guard let grained = FilmModels.applyGrainResident(cleanNegative, params: grainParams, profile: film, pixelSizeMicrometers: pixelSize, sourceOrigin: grainOrigin, sourceWidth: sourceWidth, renderScale: renderScale) else { return nil }
                negative = grained; if let grainKey { cache.put(negative, key: grainKey) }
            }
            if isCancelled() { return nil }

            var paper: MetalAccelerator.ResidentImage
            if let printKey, let cached = cache.get(printKey) { paper = cached }
            else {
                var enlarger = parameters.enlarger
                if parameters.settings.neutralPrintFiltersFromDatabase, let filters = resources.pack.neutralPrintFilters[print.id]?[enlarger.illuminant]?[film.id], filters.count >= 3 { enlarger.cFilterNeutral=filters[0]; enlarger.mFilterNeutral=filters[1]; enlarger.yFilterNeutral=filters[2] }
                guard var printExposure = SpectralService.printExposureResident(negative, film: film, print: print, resources: resources, parameters: enlarger, camera: parameters.camera, filmRendering: parameters.film) else { return nil }
                if !spatialOff && enlarger.lensBlur > 0 { guard let blurred=MetalAccelerator.shared.gaussianBlurResident(printExposure,sigmas:[enlarger.lensBlur,enlarger.lensBlur,enlarger.lensBlur]) else{return nil}; printExposure=blurred }
                guard let printLog=MetalAccelerator.shared.log10Resident(printExposure), let developed=MetalAccelerator.shared.developResident(printLog,axis:print.data.logExposure,curves:FilmModels.normalizedCurves(print.data.densityCurves),gamma:1,cacheKey:"paper:\(print.id)") else{return nil}
                paper=developed; if let printKey { cache.put(paper,key:printKey) }
            }
            if isCancelled() { return nil }

            let scannedAndCompressed: MetalAccelerator.ResidentImage
            if let scanKey, let cached = cache.get(scanKey) { scannedAndCompressed = cached }
            else {
                let glare: GlareParameters? = parameters.debug.deactivateStochasticEffects || parameters.debug.lutMode ? nil : parameters.print.glare
                guard let scanned=SpectralService.densityToRGBGamutResident(paper,profile:print,resources:resources,io:parameters.io,glare:glare) else{return nil}
                scannedAndCompressed=scanned; if let scanKey { cache.put(scannedAndCompressed,key:scanKey) }
            }
            if isCancelled() { return nil }
            return MetalAccelerator.shared.scannerFinishResident(scannedAndCompressed,parameters:parameters.scanner,io:parameters.io,spatialOff:spatialOff,gamutAlreadyApplied:true)
        }
    }
#endif

    private static func finishScannedRGB(_ image: LinearRGBImage, parameters: ScannerParameters, io: IOParameters, spatialOff: Bool, useGPU: Bool) -> LinearRGBImage {
        var out = GamutCompression.compress(image, colorSpace: io.outputColorSpace, parameters: io.outputGamutCompression)
        if !spatialOff {
            if parameters.lensBlur > 0 { out = Convolution.gaussianBlur(out, sigma: parameters.lensBlur, useGPU: useGPU) }
            if parameters.unsharpAmount != 0 { out = Convolution.unsharpMask(out, sigma: max(parameters.unsharpSigma, 0.01), amount: parameters.unsharpAmount, useGPU: useGPU) }
        }
        if parameters.blackCorrection || parameters.whiteCorrection {
            let black = parameters.blackCorrection ? parameters.blackLevel : 0
            let white = parameters.whiteCorrection ? parameters.whiteLevel : 1
            let range = max(white - black, 1e-6)
            out.mapInPlace { min(max(($0 - black) / range, 0), 1) }
        }
        if io.outputCCTFEncoding { out.mapInPlace { TransferFunction.encode(forColorSpace: io.outputColorSpace, $0) } }
        return out
    }

    private static func scanDensity(_ density: LinearRGBImage, profile: FilmProfile, resources: PipelineResources?, parameters: ScannerParameters, io: IOParameters, spatialOff: Bool, glare: GlareParameters?, useGPU: Bool) -> LinearRGBImage {
        let start = ContinuousClock.now
        var out: LinearRGBImage
        if let resources, let spectral = SpectralService.densityToRGB(density, profile: profile, resources: resources, outputColorSpace: io.outputColorSpace, glare: glare, useGPU: useGPU) {
            out = spectral
        } else {
            out = LinearRGBImage(width: density.width, height: density.height)
        var minD = [Double](repeating: .greatestFiniteMagnitude, count: 3)
        for y in 0..<density.height { for x in 0..<density.width { for c in 0..<3 { minD[c] = min(minD[c], density[x,y,c]) } } }
        for y in 0..<density.height {
            for x in 0..<density.width {
                for c in 0..<3 {
                    out[x,y,c] = pow(10, -(density[x,y,c] - minD[c]))
                }
            }
        }
        }
        out = finishScannedRGB(out, parameters: parameters, io: io, spatialOff: spatialOff, useGPU: useGPU)
        AppLog.debug("pipeline", "scanDensity done: \(AppLog.formatElapsed(AppLog.msSince(start)))")
        return out
    }

    /// Photoshop/Lightroom-style color positive conversion for a scanned
    /// negative: invert each channel and stretch per-channel auto-levels in a
    /// single pass. Inverting the unexposed film base to neutral also removes
    /// the orange mask without a separate gray-balance step. Operates on the
    /// display-space scan exactly as a photo editor would on the opened file.
    private static func invertToColorPositive(_ image: LinearRGBImage) -> LinearRGBImage {
        var hi = [Double](repeating: -.greatestFiniteMagnitude, count: 3)
        var lo = [Double](repeating: .greatestFiniteMagnitude, count: 3)
        for y in 0..<image.height { for x in 0..<image.width { for c in 0..<3 {
            hi[c] = max(hi[c], image[x, y, c])
            lo[c] = min(lo[c], image[x, y, c])
        }}}
        var out = LinearRGBImage(width: image.width, height: image.height)
        for y in 0..<out.height { for x in 0..<out.width { for c in 0..<3 {
            let range = hi[c] - lo[c]
            out[x, y, c] = range > 1e-12 ? 1 - (image[x, y, c] - lo[c]) / range : 0.5
        }}}
        return out
    }
}
