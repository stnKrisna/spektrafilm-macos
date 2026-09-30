import Foundation

public struct DiffusionFilterParameters: Sendable, Equatable {
    public var active = false
    public var family = "black_pro_mist"
    public var strength = 0.5
    public var spatialScale = 1.0
    public var haloWarmth = 0.0
    public var coreIntensity = 1.0
    public var coreSize = 1.0
    public var haloIntensity = 1.0
    public var haloSize = 1.0
    public var bloomIntensity = 1.0
    public var bloomSize = 1.0
    public init() {}
}

public struct CameraParameters: Sendable, Equatable {
    public var exposureCompensationEV: Double = 0
    public var autoExposure = true
    public var autoExposureMethod = "center_weighted"
    public var lensBlurMicrometers: Double = 0
    public var filmFormatMillimeters: Double = 35
    public var filterUV = [0.0, 410.0, 8.0]
    public var filterIR = [0.0, 675.0, 15.0]
    public var diffusionFilter = DiffusionFilterParameters()
    public init() {}
}

public struct HalationParameters: Sendable, Equatable {
    public var active = true
    public var scatterAmount = 1.0
    public var scatterSpatialScale = 1.0
    public var halationAmount = 1.0
    public var halationSpatialScale = 1.0
    public var boostEV = 0.0
    public var boostRange = 0.3
    public var protectEV = 4.0
    public var scatterCoreMicrometers = [2.2, 2.0, 1.6]
    public var scatterTailMicrometers = [9.3, 9.7, 9.1]
    public var scatterTailWeight = [0.78, 0.65, 0.67]
    public var strength = [0.05, 0.015, 0.0]
    public var firstSigmaMicrometers = [65.0, 65.0, 65.0]
    public var bounceCount = 3
    public var bounceDecay = 0.5
    public var renormalize = true
    public init() {}
}

public struct GrainParameters: Sendable, Equatable {
    public var active = true
    public var sublayersActive = true
    public var particleAreaMicrometers2 = 0.2
    public var particleScale = [1.6, 1.6, 3.2]
    public var particleScaleLayers = [2.0, 1.0, 0.5]
    public var densityMin = [0.03, 0.03, 0.03]
    public var uniformity = [0.97, 0.99, 0.97]
    public var blur = 0.65
    public var blurDyeCloudsMicrometers = 1.0
    public var microStructure = [0.2, 30.0]
    public var numberOfSublayers = 1
    /// Swift-only deterministic seed. Python uses its fast-stat RNG stream.
    public var seed: UInt64 = 12_345
    public init() {}
}

public struct DIRCouplersParameters: Sendable, Equatable {
    public var active = true
    public var amount = 1.0
    public var inhibitionSameLayer = 1.0
    public var inhibitionInterLayer = 1.0
    public var gammaSameLayerRGB = [0.341, 0.324, 0.273]
    public var gammaInterLayerRToGB = [0.355, 0.305]
    public var gammaInterLayerGToRB = [0.154, 0.358]
    public var gammaInterLayerBToRG = [0.171, 0.225]
    public var diffusionSizeMicrometers = 20.0
    public var diffusionTailMicrometers = 200.0
    public var diffusionTailWeight = 0.06
    public init() {}
}

public struct GlareParameters: Sendable, Equatable {
    public var active = true
    public var percent = 0.03
    public var roughness = 0.7
    public var blur = 0.5
    /// Swift-only deterministic seed for repeatable renders.
    public var seed: UInt64 = 12_345
    public init() {}
}

public struct FilmRenderingParameters: Sendable, Equatable {
    public var densityCurveGamma = 1.0
    public var grain = GrainParameters()
    public var halation = HalationParameters()
    public var dirCouplers = DIRCouplersParameters()
    public var glare = GlareParameters()
    public init() {}
}

public struct EnlargerParameters: Sendable, Equatable {
    public var illuminant = "TH-KG3"
    public var printExposure = 1.0
    public var printExposureCompensation = true
    public var normalizePrintExposure = true
    public var yFilterShift = 0.0
    public var mFilterShift = 0.0
    public var yFilterNeutral = 55.0
    public var mFilterNeutral = 65.0
    public var cFilterNeutral = 0.0
    public var lensBlur = 0.0
    public var diffusionFilter = DiffusionFilterParameters()
    public var preflashExposure = 0.0
    public var preflashYFilterShift = 0.0
    public var preflashMFilterShift = 0.0
    public init() {}
}

public struct PrintCurvesMorphParameters: Sendable, Equatable {
    public var active = false
    public var gammaFactor = 1.0
    public var gammaFactorFast = 1.0
    public var gammaFactorSlow = 1.0
    public var gammaFactorRed = 1.0
    public var gammaFactorGreen = 1.0
    public var gammaFactorBlue = 1.0
    public var developerExhaustion = 0.0
    public init() {}
}

public struct PrintRenderingParameters: Sendable, Equatable {
    public var glare = GlareParameters()
    public var densityCurvesMorph = PrintCurvesMorphParameters()
    public init() {}
}

public struct ScannerParameters: Sendable, Equatable {
    public var lensBlur = 0.0
    public var whiteCorrection = false
    public var blackCorrection = false
    public var whiteLevel = 0.98
    public var blackLevel = 0.01
    public var unsharpSigma = 0.7
    public var unsharpAmount = 0.7
    public init() {}
}

public struct InputGamutCompressionParameters: Sendable, Equatable {
    public var active = true
    public var threshold = 0.0
    public var limit = 1.0
    public var power = 6.0
    public init() {}
}

public struct OutputGamutCompressionParameters: Sendable, Equatable {
    public var active = true
    public var threshold = 0.0
    public var limit = 1.0
    public var power = 6.0
    public init() {}
}

public struct IOParameters: Sendable, Equatable {
    public var inputColorSpace = "ProPhoto RGB"
    public var inputCCTFDecoding = false
    public var outputColorSpace = "sRGB"
    public var outputCCTFEncoding = true
    public var inputGamutCompression = InputGamutCompressionParameters()
    public var outputGamutCompression = OutputGamutCompressionParameters()
    public var crop = false
    public var cropCenter = [0.5, 0.5]
    public var cropSize = [0.1, 0.1]
    public var upscale = 1.0
    public var scanFilm = false
    /// When scanning a negative directly (print: nil / scanFilm), invert the
    /// scanned density into a color positive using per-channel auto-levels —
    /// the same simple inversion you would do on a negative scan in a photo
    /// editor. Skipped automatically when a print profile is used (the print
    /// is already a positive).
    public var colorPositive = true
    public init() {}
}

public struct DebugParameters: Sendable, Equatable {
    public var deactivateSpatialEffects = false
    public var deactivateStochasticEffects = false
    public var printTimings = false
    public var lutMode = false
    public var enableFixedTileRefinement = false
    public init() {}
}

public struct TapsParameters: Sendable, Equatable {
    public var inject: String? = nil
    public var collect: String? = nil
    public init() {}
}

public struct SettingsParameters: Sendable, Equatable {
    public var rgbToRawMethod = "hanatos2025"
    public var applyHanatosAdaptationWindow = true
    public var applyHanatosAdaptationSurface = false
    public var spectralGaussianBlur = 0.0
    public var useEnlargerLUT = false
    public var useScannerLUT = false
    public var lutResolution = 17
    public var useFastStats = false
    public var previewMaxSize = 1024
    public var previewMode = false
    /// Use the Float32 Metal backend for interactive preview math on supported Macs.
    public var useMetalPreview = true
    /// Float32 Metal acceleration for full-resolution export on supported Macs.
    public var useMetalExport = true
    public var neutralPrintFiltersFromDatabase = true
    public init() {}
}

public struct RenderParameters: Sendable, Equatable {
    public var camera = CameraParameters()
    public var film = FilmRenderingParameters()
    public var enlarger = EnlargerParameters()
    public var print = PrintRenderingParameters()
    public var scanner = ScannerParameters()
    public var io = IOParameters()
    public var debug = DebugParameters()
    public var taps = TapsParameters()
    public var settings = SettingsParameters()

    public var scanFilm: Bool {
        get { io.scanFilm }
        set { io.scanFilm = newValue }
    }
    public var outputCCTFEncoding: Bool {
        get { io.outputCCTFEncoding }
        set { io.outputCCTFEncoding = newValue }
    }
    public init() {}
}
