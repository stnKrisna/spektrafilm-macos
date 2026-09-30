#if os(macOS)
import AppKit
import SwiftUI
import SpektrafilmCore

extension Inspector {
    // MARK: - Full control groups

    @ViewBuilder
    var rawFullControls: some View {
        Text("Applied by Core Image before the Spektrafilm camera/film simulation.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ParameterSlider("Exposure", value: $imageService.rawAdjustments.exposureEV, range: -5...5, suffix: " EV", defaultValue: RAWAdjustments.default.exposureEV)
        ParameterSlider("Temperature", value: $imageService.rawAdjustments.temperature, range: 2000...50000, suffix: " K", defaultValue: RAWAdjustments.default.temperature)
        ParameterSlider("Tint", value: $imageService.rawAdjustments.tint, range: -150...150, defaultValue: RAWAdjustments.default.tint)
        ParameterToggle("Lens correction", isOn: $imageService.rawAdjustments.lensCorrectionEnabled, defaultValue: RAWAdjustments.default.lensCorrectionEnabled)
        HStack {
            Spacer()
            Button("Reset to camera defaults") { imageService.resetRAWAdjustments() }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    var cameraFullControls: some View {
        ParameterSlider("Exposure compensation", value: $model.parameters.camera.exposureCompensationEV, range: -6...6, suffix: " EV", defaultValue: CameraParameters().exposureCompensationEV)
        ParameterToggle("Auto exposure", isOn: $model.parameters.camera.autoExposure, defaultValue: CameraParameters().autoExposure)
        if model.parameters.camera.autoExposure {
            ParameterPicker(
                "AE method",
                selection: $model.parameters.camera.autoExposureMethod,
                options: ["center_weighted", "median", "mean", "percentile"],
                defaultValue: CameraParameters().autoExposureMethod
            )
        }
        ParameterSlider("Lens blur", value: $model.parameters.camera.lensBlurMicrometers, range: 0...50, suffix: " µm", defaultValue: CameraParameters().lensBlurMicrometers)
        FilmFormatControl(value: $model.parameters.camera.filmFormatMillimeters)
        Vector3Editor(
            "UV filter",
            values: $model.parameters.camera.filterUV,
            labels: ["Strength", "Cutoff", "Width"],
            ranges: [0...1, 350...500, 1...80],
            defaults: CameraParameters().filterUV
        )
        Vector3Editor(
            "IR filter",
            values: $model.parameters.camera.filterIR,
            labels: ["Strength", "Cutoff", "Width"],
            ranges: [0...1, 550...850, 1...100],
            defaults: CameraParameters().filterIR
        )
        DiffusionFilterEditor(title: "Camera diffusion", parameters: $model.parameters.camera.diffusionFilter)
    }

    @ViewBuilder
    var filmDevelopmentFullControls: some View {
        ParameterSlider("Density gamma", value: $model.parameters.film.densityCurveGamma, range: 0.25...3, defaultValue: FilmRenderingParameters().densityCurveGamma)
        EffectDisclosure("DIR couplers", isOn: $model.parameters.film.dirCouplers.active, defaultIsOn: DIRCouplersParameters().active, initiallyExpanded: true) {
            ParameterSlider("DIR amount", value: $model.parameters.film.dirCouplers.amount, range: 0...2, defaultValue: DIRCouplersParameters().amount)
            ParameterSlider("Same-layer inhibition", value: $model.parameters.film.dirCouplers.inhibitionSameLayer, range: 0...2, defaultValue: DIRCouplersParameters().inhibitionSameLayer)
            ParameterSlider("Inter-layer inhibition", value: $model.parameters.film.dirCouplers.inhibitionInterLayer, range: 0...2, defaultValue: DIRCouplersParameters().inhibitionInterLayer)
            Vector3Editor(
                "Same-layer gamma",
                values: $model.parameters.film.dirCouplers.gammaSameLayerRGB,
                labels: ["R", "G", "B"],
                ranges: Array(repeating: 0...1, count: 3),
                defaults: DIRCouplersParameters().gammaSameLayerRGB
            )
            Vector2Editor(
                "R → G/B",
                values: $model.parameters.film.dirCouplers.gammaInterLayerRToGB,
                labels: ["G", "B"],
                ranges: Array(repeating: 0...1, count: 2),
                defaults: DIRCouplersParameters().gammaInterLayerRToGB
            )
            Vector2Editor(
                "G → R/B",
                values: $model.parameters.film.dirCouplers.gammaInterLayerGToRB,
                labels: ["R", "B"],
                ranges: Array(repeating: 0...1, count: 2),
                defaults: DIRCouplersParameters().gammaInterLayerGToRB
            )
            Vector2Editor(
                "B → R/G",
                values: $model.parameters.film.dirCouplers.gammaInterLayerBToRG,
                labels: ["R", "G"],
                ranges: Array(repeating: 0...1, count: 2),
                defaults: DIRCouplersParameters().gammaInterLayerBToRG
            )
            ParameterSlider("Diffusion size", value: $model.parameters.film.dirCouplers.diffusionSizeMicrometers, range: 0...100, suffix: " µm", defaultValue: DIRCouplersParameters().diffusionSizeMicrometers)
            ParameterSlider("Diffusion tail", value: $model.parameters.film.dirCouplers.diffusionTailMicrometers, range: 0...500, suffix: " µm", defaultValue: DIRCouplersParameters().diffusionTailMicrometers)
            ParameterSlider("Tail weight", value: $model.parameters.film.dirCouplers.diffusionTailWeight, range: 0...1, defaultValue: DIRCouplersParameters().diffusionTailWeight)
        }
    }

    @ViewBuilder
    var halationFullControls: some View {
        ParameterSlider("Scatter amount", value: $model.parameters.film.halation.scatterAmount, range: 0...3, defaultValue: HalationParameters().scatterAmount)
        ParameterSlider("Scatter spatial scale", value: $model.parameters.film.halation.scatterSpatialScale, range: 0.1...4, defaultValue: HalationParameters().scatterSpatialScale)
        ParameterSlider("Halation amount", value: $model.parameters.film.halation.halationAmount, range: 0...3, defaultValue: HalationParameters().halationAmount)
        ParameterSlider("Halation spatial scale", value: $model.parameters.film.halation.halationSpatialScale, range: 0.1...4, defaultValue: HalationParameters().halationSpatialScale)
        ParameterSlider("Boost", value: $model.parameters.film.halation.boostEV, range: -2...4, suffix: " EV", defaultValue: HalationParameters().boostEV)
        ParameterSlider("Boost range", value: $model.parameters.film.halation.boostRange, range: 0...2, defaultValue: HalationParameters().boostRange)
        ParameterSlider("Protect", value: $model.parameters.film.halation.protectEV, range: 0...10, suffix: " EV", defaultValue: HalationParameters().protectEV)
        Vector3Editor(
            "Scatter core",
            values: $model.parameters.film.halation.scatterCoreMicrometers,
            labels: ["R", "G", "B"],
            ranges: Array(repeating: 0...30, count: 3),
            suffix: " µm",
            defaults: HalationParameters().scatterCoreMicrometers
        )
        Vector3Editor(
            "Scatter tail",
            values: $model.parameters.film.halation.scatterTailMicrometers,
            labels: ["R", "G", "B"],
            ranges: Array(repeating: 0...100, count: 3),
            suffix: " µm",
            defaults: HalationParameters().scatterTailMicrometers
        )
        Vector3Editor(
            "Tail weight",
            values: $model.parameters.film.halation.scatterTailWeight,
            labels: ["R", "G", "B"],
            ranges: Array(repeating: 0...1, count: 3),
            defaults: HalationParameters().scatterTailWeight
        )
        Vector3Editor(
            "Halation strength",
            values: $model.parameters.film.halation.strength,
            labels: ["R", "G", "B"],
            ranges: Array(repeating: 0...0.5, count: 3),
            defaults: HalationParameters().strength
        )
        Vector3Editor(
            "First sigma",
            values: $model.parameters.film.halation.firstSigmaMicrometers,
            labels: ["R", "G", "B"],
            ranges: Array(repeating: 0...250, count: 3),
            suffix: " µm",
            defaults: HalationParameters().firstSigmaMicrometers
        )
        IntegerStepper("Bounces", value: $model.parameters.film.halation.bounceCount, range: 1...12, defaultValue: HalationParameters().bounceCount)
        ParameterSlider("Bounce decay", value: $model.parameters.film.halation.bounceDecay, range: 0...1, defaultValue: HalationParameters().bounceDecay)
        ParameterToggle("Renormalize", isOn: $model.parameters.film.halation.renormalize, defaultValue: HalationParameters().renormalize)
    }

    @ViewBuilder
    var grainFullControls: some View {
        ParameterToggle("Sublayers", isOn: $model.parameters.film.grain.sublayersActive, defaultValue: GrainParameters().sublayersActive)
        ParameterSlider("Particle area", value: $model.parameters.film.grain.particleAreaMicrometers2, range: 0.01...2, suffix: " µm²", defaultValue: GrainParameters().particleAreaMicrometers2)
        Vector3Editor(
            "Particle scale RGB",
            values: $model.parameters.film.grain.particleScale,
            labels: ["R", "G", "B"],
            ranges: Array(repeating: 0.1...8, count: 3),
            defaults: GrainParameters().particleScale
        )
        Vector3Editor(
            "Layer scale",
            values: $model.parameters.film.grain.particleScaleLayers,
            labels: ["Fast", "Mid", "Slow"],
            ranges: Array(repeating: 0.1...8, count: 3),
            defaults: GrainParameters().particleScaleLayers
        )
        Vector3Editor(
            "Minimum density",
            values: $model.parameters.film.grain.densityMin,
            labels: ["R", "G", "B"],
            ranges: Array(repeating: 0...0.5, count: 3),
            defaults: GrainParameters().densityMin
        )
        Vector3Editor(
            "Uniformity",
            values: $model.parameters.film.grain.uniformity,
            labels: ["R", "G", "B"],
            ranges: Array(repeating: 0.5...1, count: 3),
            defaults: GrainParameters().uniformity
        )
        ParameterSlider("Blur", value: $model.parameters.film.grain.blur, range: 0...3, defaultValue: GrainParameters().blur)
        ParameterSlider("Dye-cloud blur", value: $model.parameters.film.grain.blurDyeCloudsMicrometers, range: 0...20, suffix: " µm", defaultValue: GrainParameters().blurDyeCloudsMicrometers)
        Vector2Editor(
            "Microstructure",
            values: $model.parameters.film.grain.microStructure,
            labels: ["Amount", "Scale"],
            ranges: [0...2, 0...100],
            defaults: GrainParameters().microStructure
        )
        IntegerStepper("Number of sublayers", value: $model.parameters.film.grain.numberOfSublayers, range: 1...16, defaultValue: GrainParameters().numberOfSublayers)
        UInt64Field("Seed", value: $model.parameters.film.grain.seed, defaultValue: GrainParameters().seed)
    }

    @ViewBuilder
    func glareControls(_ parameters: Binding<GlareParameters>) -> some View {
        ParameterSlider("Percent", value: parameters.percent, range: 0...0.25, defaultValue: GlareParameters().percent)
        ParameterSlider("Roughness", value: parameters.roughness, range: 0...2, defaultValue: GlareParameters().roughness)
        ParameterSlider("Blur", value: parameters.blur, range: 0...5, defaultValue: GlareParameters().blur)
        UInt64Field("Seed", value: parameters.seed, defaultValue: GlareParameters().seed)
    }

    @ViewBuilder
    var enlargerFullControls: some View {
        HStack(spacing: 6) {
            TextField("Illuminant", text: $model.parameters.enlarger.illuminant)
                .textFieldStyle(.roundedBorder)
            ParameterResetButton(
                isDefault: model.parameters.enlarger.illuminant == EnlargerParameters().illuminant,
                reset: { model.parameters.enlarger.illuminant = EnlargerParameters().illuminant }
            )
        }
        ParameterSlider("Print exposure", value: $model.parameters.enlarger.printExposure, range: 0.05...8, defaultValue: EnlargerParameters().printExposure)
        ParameterToggle("Exposure compensation", isOn: $model.parameters.enlarger.printExposureCompensation, defaultValue: EnlargerParameters().printExposureCompensation)
        ParameterToggle("Normalize print exposure", isOn: $model.parameters.enlarger.normalizePrintExposure, defaultValue: EnlargerParameters().normalizePrintExposure)
        ParameterSlider("Yellow filter shift", value: $model.parameters.enlarger.yFilterShift, range: -100...100, defaultValue: EnlargerParameters().yFilterShift)
        ParameterSlider("Magenta filter shift", value: $model.parameters.enlarger.mFilterShift, range: -100...100, defaultValue: EnlargerParameters().mFilterShift)
        ParameterSlider("Neutral yellow", value: $model.parameters.enlarger.yFilterNeutral, range: 0...200, defaultValue: EnlargerParameters().yFilterNeutral)
        ParameterSlider("Neutral magenta", value: $model.parameters.enlarger.mFilterNeutral, range: 0...200, defaultValue: EnlargerParameters().mFilterNeutral)
        ParameterSlider("Neutral cyan", value: $model.parameters.enlarger.cFilterNeutral, range: 0...200, defaultValue: EnlargerParameters().cFilterNeutral)
        ParameterSlider("Lens blur", value: $model.parameters.enlarger.lensBlur, range: 0...10, defaultValue: EnlargerParameters().lensBlur)
        ParameterSlider("Preflash exposure", value: $model.parameters.enlarger.preflashExposure, range: 0...2, defaultValue: EnlargerParameters().preflashExposure)
        ParameterSlider("Preflash yellow shift", value: $model.parameters.enlarger.preflashYFilterShift, range: -100...100, defaultValue: EnlargerParameters().preflashYFilterShift)
        ParameterSlider("Preflash magenta shift", value: $model.parameters.enlarger.preflashMFilterShift, range: -100...100, defaultValue: EnlargerParameters().preflashMFilterShift)
        DiffusionFilterEditor(title: "Enlarger diffusion", parameters: $model.parameters.enlarger.diffusionFilter)
    }

    @ViewBuilder
    var printFullControls: some View {
        EffectDisclosure("Curve morph", isOn: $model.parameters.print.densityCurvesMorph.active, defaultIsOn: PrintCurvesMorphParameters().active) {
            ParameterSlider("Gamma", value: $model.parameters.print.densityCurvesMorph.gammaFactor, range: 0.25...3, defaultValue: PrintCurvesMorphParameters().gammaFactor)
            ParameterSlider("Fast gamma", value: $model.parameters.print.densityCurvesMorph.gammaFactorFast, range: 0.25...3, defaultValue: PrintCurvesMorphParameters().gammaFactorFast)
            ParameterSlider("Slow gamma", value: $model.parameters.print.densityCurvesMorph.gammaFactorSlow, range: 0.25...3, defaultValue: PrintCurvesMorphParameters().gammaFactorSlow)
            ParameterSlider("Red gamma", value: $model.parameters.print.densityCurvesMorph.gammaFactorRed, range: 0.25...3, defaultValue: PrintCurvesMorphParameters().gammaFactorRed)
            ParameterSlider("Green gamma", value: $model.parameters.print.densityCurvesMorph.gammaFactorGreen, range: 0.25...3, defaultValue: PrintCurvesMorphParameters().gammaFactorGreen)
            ParameterSlider("Blue gamma", value: $model.parameters.print.densityCurvesMorph.gammaFactorBlue, range: 0.25...3, defaultValue: PrintCurvesMorphParameters().gammaFactorBlue)
            ParameterSlider("Developer exhaustion", value: $model.parameters.print.densityCurvesMorph.developerExhaustion, range: 0...1, defaultValue: PrintCurvesMorphParameters().developerExhaustion)
        }

        EffectDisclosure("Print glare", isOn: $model.parameters.print.glare.active, defaultIsOn: GlareParameters().active) {
            glareControls($model.parameters.print.glare)
        }
    }

    @ViewBuilder
    var scannerFullControls: some View {
        ParameterSlider("Lens blur", value: $model.parameters.scanner.lensBlur, range: 0...10, defaultValue: ScannerParameters().lensBlur)
        ParameterToggle("White correction", isOn: $model.parameters.scanner.whiteCorrection, defaultValue: ScannerParameters().whiteCorrection)
        ParameterToggle("Black correction", isOn: $model.parameters.scanner.blackCorrection, defaultValue: ScannerParameters().blackCorrection)
        ParameterSlider("White level", value: $model.parameters.scanner.whiteLevel, range: 0.5...1.5, defaultValue: ScannerParameters().whiteLevel)
        ParameterSlider("Black level", value: $model.parameters.scanner.blackLevel, range: -0.25...0.25, defaultValue: ScannerParameters().blackLevel)
        ParameterSlider("Unsharp sigma", value: $model.parameters.scanner.unsharpSigma, range: 0...5, defaultValue: ScannerParameters().unsharpSigma)
        ParameterSlider("Unsharp amount", value: $model.parameters.scanner.unsharpAmount, range: 0...3, defaultValue: ScannerParameters().unsharpAmount)
    }

    @ViewBuilder
    var ioFullControls: some View {
        ParameterPicker("Input color space", selection: $model.parameters.io.inputColorSpace, options: ColorSpaceOptions.all, defaultValue: IOParameters().inputColorSpace)
        ParameterToggle("Decode input CCTF", isOn: $model.parameters.io.inputCCTFDecoding, defaultValue: IOParameters().inputCCTFDecoding)
        GamutCompressionEditor(
            title: "Input gamut compression",
            active: $model.parameters.io.inputGamutCompression.active,
            threshold: $model.parameters.io.inputGamutCompression.threshold,
            limit: $model.parameters.io.inputGamutCompression.limit,
            power: $model.parameters.io.inputGamutCompression.power
        )
        Divider()
        ParameterPicker("Output color space", selection: $model.parameters.io.outputColorSpace, options: ColorSpaceOptions.all, defaultValue: IOParameters().outputColorSpace)
        ParameterToggle("Encode output CCTF", isOn: $model.parameters.io.outputCCTFEncoding, defaultValue: IOParameters().outputCCTFEncoding)
        GamutCompressionEditor(
            title: "Output gamut compression",
            active: $model.parameters.io.outputGamutCompression.active,
            threshold: $model.parameters.io.outputGamutCompression.threshold,
            limit: $model.parameters.io.outputGamutCompression.limit,
            power: $model.parameters.io.outputGamutCompression.power
        )
        Divider()
        ParameterToggle("Crop", isOn: $model.parameters.io.crop, defaultValue: IOParameters().crop)
        if model.parameters.io.crop {
            Vector2Editor("Crop center", values: $model.parameters.io.cropCenter, labels: ["X", "Y"], ranges: [0...1, 0...1], defaults: IOParameters().cropCenter)
            Vector2Editor("Crop size", values: $model.parameters.io.cropSize, labels: ["W", "H"], ranges: [0.01...1, 0.01...1], defaults: IOParameters().cropSize)
        }
        ParameterSlider("Upscale", value: $model.parameters.io.upscale, range: 0.25...4, suffix: "×", defaultValue: IOParameters().upscale)
        ParameterToggle("Scan film directly", isOn: $model.parameters.io.scanFilm, defaultValue: IOParameters().scanFilm)
        ParameterToggle("Color positive (invert scan)", isOn: $model.parameters.io.colorPositive, defaultValue: IOParameters().colorPositive)
            .help("Invert a direct negative scan into a color positive via per-channel auto-levels. Applies only when no print profile is used.")
    }

    @ViewBuilder
    var engineFullControls: some View {
        ParameterPicker("RGB → spectral", selection: $model.parameters.settings.rgbToRawMethod, options: ["hanatos2025", "mallett2019"], defaultValue: SettingsParameters().rgbToRawMethod)
        ParameterToggle("Hanatos adaptation window", isOn: $model.parameters.settings.applyHanatosAdaptationWindow, defaultValue: SettingsParameters().applyHanatosAdaptationWindow)
        ParameterToggle("Hanatos adaptation surface", isOn: $model.parameters.settings.applyHanatosAdaptationSurface, defaultValue: SettingsParameters().applyHanatosAdaptationSurface)
        ParameterSlider("Spectral Gaussian blur", value: $model.parameters.settings.spectralGaussianBlur, range: 0...10, defaultValue: SettingsParameters().spectralGaussianBlur)
        ParameterToggle("Use enlarger LUT", isOn: $model.parameters.settings.useEnlargerLUT, defaultValue: SettingsParameters().useEnlargerLUT)
        ParameterToggle("Use scanner LUT", isOn: $model.parameters.settings.useScannerLUT, defaultValue: SettingsParameters().useScannerLUT)
        IntegerStepper("LUT resolution", value: $model.parameters.settings.lutResolution, range: 5...65, defaultValue: SettingsParameters().lutResolution)
        ParameterToggle("Fast statistics", isOn: $model.parameters.settings.useFastStats, defaultValue: SettingsParameters().useFastStats)
    }

    @ViewBuilder
    var engineDebugOnlyControls: some View {
        IntegerStepper("Preview max size", value: $model.parameters.settings.previewMaxSize, range: 128...4096, step: 64, defaultValue: SettingsParameters().previewMaxSize)
        ParameterToggle("Preview mode", isOn: $model.parameters.settings.previewMode, defaultValue: SettingsParameters().previewMode)
        ParameterToggle("Metal preview acceleration", isOn: $model.parameters.settings.useMetalPreview, defaultValue: SettingsParameters().useMetalPreview)
        ParameterToggle("Metal export acceleration (Float32)", isOn: $model.parameters.settings.useMetalExport, defaultValue: SettingsParameters().useMetalExport)
        ParameterToggle("Neutral print filters from database", isOn: $model.parameters.settings.neutralPrintFiltersFromDatabase, defaultValue: SettingsParameters().neutralPrintFiltersFromDatabase)
    }

    @ViewBuilder
    var debugFullControls: some View {
        ParameterToggle("Disable spatial effects", isOn: $model.parameters.debug.deactivateSpatialEffects, defaultValue: DebugParameters().deactivateSpatialEffects)
        ParameterToggle("Disable stochastic effects", isOn: $model.parameters.debug.deactivateStochasticEffects, defaultValue: DebugParameters().deactivateStochasticEffects)
        ParameterToggle("Print timings", isOn: $model.parameters.debug.printTimings, defaultValue: DebugParameters().printTimings)
        ParameterToggle("LUT mode", isOn: $model.parameters.debug.lutMode, defaultValue: DebugParameters().lutMode)
        ParameterToggle("Enable 640px grid refresh", isOn: $model.parameters.debug.enableFixedTileRefinement, defaultValue: DebugParameters().enableFixedTileRefinement)
        OptionalStringField("Inject tap", value: $model.parameters.taps.inject)
        OptionalStringField("Collect tap", value: $model.parameters.taps.collect)
    }
}
#endif
