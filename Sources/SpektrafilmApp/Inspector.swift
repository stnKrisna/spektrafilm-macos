#if os(macOS)
import AppKit
import SwiftUI
import SpektrafilmCore

struct Inspector: View {
    @EnvironmentObject var model: AppViewModel
    @EnvironmentObject var profiles: ProfileService
    @EnvironmentObject var imageService: ImageService
    @EnvironmentObject var previews: ProfilePreviewsService
    @AppStorage(AdjustmentInterfacePreferences.modeKey)
    private var interfaceModeRaw = AdjustmentInterfacePreferences.defaultMode
    @AppStorage(AdjustmentInterfacePreferences.soloPanelsKey)
    private var soloPanels = true

    @State private var expandedPanelID: String? = "film"

    private var interfaceMode: AdjustmentInterfaceMode {
        AdjustmentInterfaceMode(rawValue: interfaceModeRaw) ?? .basic
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                switch interfaceMode {
                case .quick:
                    quickLayout
                case .basic:
                    basicLayout
                case .advanced:
                    advancedLayout
                case .debug:
                    debugLayout
                }
            }
            .padding(12)
        }
        .onChange(of: model.parameters) { old, new in model.parametersChanged(from: old, to: new) }
        .onChange(of: imageService.rawAdjustments) { _, _ in imageService.rawAdjustmentsChanged() }
        .onChange(of: interfaceModeRaw) { _, _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedPanelID = interfaceMode == .debug ? nil : "film"
            }
        }
    }

    // MARK: - Quick

    @ViewBuilder
    private var quickLayout: some View {
        panel("film", "Film", systemImage: "film", defaultExpanded: true) {
            filmProfileBrowser(height: 280, thumbnailSize: 104, initialLayout: "grid")
            Divider()
            FilmFormatControl(value: $model.parameters.camera.filmFormatMillimeters)
        }

        panel("print", "Print", systemImage: "photo.on.rectangle.angled") {
            printProfileBrowser(height: 220, thumbnailSize: 104, initialLayout: "grid")
        }

        panel(
            "quick-adjust",
            "Quick Adjustments",
            systemImage: "bolt",
            modified: quickAdjustmentsModified
        ) {
            if imageService.isRAWSource {
                ControlGroupTitle("RAW")
                ParameterSlider("RAW exposure", value: $imageService.rawAdjustments.exposureEV, range: -5...5, suffix: " EV", defaultValue: RAWAdjustments.default.exposureEV)
                ParameterSlider("Temperature", value: $imageService.rawAdjustments.temperature, range: 2000...50000, suffix: " K", defaultValue: RAWAdjustments.default.temperature)
                ParameterSlider("Tint", value: $imageService.rawAdjustments.tint, range: -150...150, defaultValue: RAWAdjustments.default.tint)
                Divider()
            }

            ParameterSlider("Exposure", value: $model.parameters.camera.exposureCompensationEV, range: -6...6, suffix: " EV", defaultValue: CameraParameters().exposureCompensationEV)
            ParameterSlider("Film contrast", value: $model.parameters.film.densityCurveGamma, range: 0.5...1.75, defaultValue: FilmRenderingParameters().densityCurveGamma)
            ParameterSlider("Print exposure", value: $model.parameters.enlarger.printExposure, range: 0.25...3, defaultValue: EnlargerParameters().printExposure)

            EffectDisclosure("Halation", isOn: $model.parameters.film.halation.active, defaultIsOn: HalationParameters().active, initiallyExpanded: true) {
                ParameterSlider("Amount", value: $model.parameters.film.halation.halationAmount, range: 0...2, defaultValue: HalationParameters().halationAmount)
            }

            EffectDisclosure("Grain", isOn: $model.parameters.film.grain.active, defaultIsOn: GrainParameters().active) {
                ParameterSlider("Particle size", value: $model.parameters.film.grain.particleAreaMicrometers2, range: 0.01...1, suffix: " µm²", defaultValue: GrainParameters().particleAreaMicrometers2)
            }

            ParameterSlider("Sharpness", value: $model.parameters.scanner.unsharpAmount, range: 0...2, defaultValue: ScannerParameters().unsharpAmount)

            Divider()
            ParameterToggle("Scan film directly", isOn: $model.parameters.io.scanFilm, defaultValue: IOParameters().scanFilm)
            ParameterToggle("Color positive (invert scan)", isOn: $model.parameters.io.colorPositive, defaultValue: IOParameters().colorPositive)
                .help("Invert a direct negative scan into a color positive via per-channel auto-levels. Applies only when no print profile is used.")
        }
    }

    // MARK: - Basic

    @ViewBuilder
    private var basicLayout: some View {
        panel("film", "Film", systemImage: "film", defaultExpanded: true) {
            filmProfileBrowser(height: 300, thumbnailSize: 112, initialLayout: "grid")
        }

        panel("print", "Print", systemImage: "photo.on.rectangle.angled") {
            printProfileBrowser(height: 240, thumbnailSize: 112, initialLayout: "grid")
        }

        panel(
            "light",
            "Light & Color",
            systemImage: "sun.max",
            modified: lightControlsModified
        ) {
            if imageService.isRAWSource {
                ControlGroupTitle("RAW Development")
                ParameterSlider("Exposure", value: $imageService.rawAdjustments.exposureEV, range: -5...5, suffix: " EV", defaultValue: RAWAdjustments.default.exposureEV)
                ParameterSlider("Temperature", value: $imageService.rawAdjustments.temperature, range: 2000...50000, suffix: " K", defaultValue: RAWAdjustments.default.temperature)
                ParameterSlider("Tint", value: $imageService.rawAdjustments.tint, range: -150...150, defaultValue: RAWAdjustments.default.tint)
                ParameterToggle("Lens correction", isOn: $imageService.rawAdjustments.lensCorrectionEnabled, defaultValue: RAWAdjustments.default.lensCorrectionEnabled)
                Divider()
            }

            ControlGroupTitle("Film Exposure")
            ParameterSlider("Exposure compensation", value: $model.parameters.camera.exposureCompensationEV, range: -6...6, suffix: " EV", defaultValue: CameraParameters().exposureCompensationEV)
            ParameterToggle("Auto exposure", isOn: $model.parameters.camera.autoExposure, defaultValue: CameraParameters().autoExposure)
            ParameterSlider("Film contrast", value: $model.parameters.film.densityCurveGamma, range: 0.5...1.75, defaultValue: FilmRenderingParameters().densityCurveGamma)

            Divider()
            ControlGroupTitle("Print")
            ParameterSlider("Print exposure", value: $model.parameters.enlarger.printExposure, range: 0.25...3, defaultValue: EnlargerParameters().printExposure)
            ParameterToggle("Normalize print exposure", isOn: $model.parameters.enlarger.normalizePrintExposure, defaultValue: EnlargerParameters().normalizePrintExposure)
        }

        panel(
            "character",
            "Film Character",
            systemImage: "camera.filters",
            modified: filmCharacterModified
        ) {
            FilmFormatControl(value: $model.parameters.camera.filmFormatMillimeters)

            EffectDisclosure("Halation", isOn: $model.parameters.film.halation.active, defaultIsOn: HalationParameters().active, initiallyExpanded: true) {
                ParameterSlider("Amount", value: $model.parameters.film.halation.halationAmount, range: 0...2, defaultValue: HalationParameters().halationAmount)
                ParameterSlider("Scatter", value: $model.parameters.film.halation.scatterAmount, range: 0...2, defaultValue: HalationParameters().scatterAmount)
            }

            EffectDisclosure("Grain", isOn: $model.parameters.film.grain.active, defaultIsOn: GrainParameters().active) {
                ParameterSlider("Particle size", value: $model.parameters.film.grain.particleAreaMicrometers2, range: 0.01...1, suffix: " µm²", defaultValue: GrainParameters().particleAreaMicrometers2)
                ParameterSlider("Softness", value: $model.parameters.film.grain.blur, range: 0...2, defaultValue: GrainParameters().blur)
            }

            EffectDisclosure("Film glare", isOn: $model.parameters.film.glare.active, defaultIsOn: GlareParameters().active) {
                ParameterSlider("Amount", value: $model.parameters.film.glare.percent, range: 0...0.15, defaultValue: GlareParameters().percent)
                ParameterSlider("Softness", value: $model.parameters.film.glare.blur, range: 0...3, defaultValue: GlareParameters().blur)
            }
        }

        panel(
            "detail",
            "Detail",
            systemImage: "viewfinder",
            modified: detailControlsModified
        ) {
            ParameterSlider("Camera softness", value: $model.parameters.camera.lensBlurMicrometers, range: 0...50, suffix: " µm", defaultValue: CameraParameters().lensBlurMicrometers)
            ParameterSlider("Scanner softness", value: $model.parameters.scanner.lensBlur, range: 0...10, defaultValue: ScannerParameters().lensBlur)
            ParameterSlider("Sharpness", value: $model.parameters.scanner.unsharpAmount, range: 0...3, defaultValue: ScannerParameters().unsharpAmount)
            ParameterSlider("Sharpness radius", value: $model.parameters.scanner.unsharpSigma, range: 0...5, defaultValue: ScannerParameters().unsharpSigma)
            ParameterToggle("White correction", isOn: $model.parameters.scanner.whiteCorrection, defaultValue: ScannerParameters().whiteCorrection)
            ParameterToggle("Black correction", isOn: $model.parameters.scanner.blackCorrection, defaultValue: ScannerParameters().blackCorrection)
        }

        panel(
            "output",
            "Output",
            systemImage: "paintpalette",
            modified: outputControlsModified
        ) {
            ParameterPicker("Output color space", selection: $model.parameters.io.outputColorSpace, options: ColorSpaceOptions.all, defaultValue: IOParameters().outputColorSpace)
            ParameterToggle("Encode output transfer function", isOn: $model.parameters.io.outputCCTFEncoding, defaultValue: IOParameters().outputCCTFEncoding)
            ParameterToggle("Scan film directly", isOn: $model.parameters.io.scanFilm, defaultValue: IOParameters().scanFilm)
            ParameterToggle("Color positive (invert scan)", isOn: $model.parameters.io.colorPositive, defaultValue: IOParameters().colorPositive)
                .help("Invert a direct negative scan into a color positive via per-channel auto-levels. Applies only when no print profile is used.")
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedLayout: some View {
        panel("film", "Film & Print Profiles", systemImage: "rectangle.stack", defaultExpanded: true) {
            filmProfileBrowser(height: 300, thumbnailSize: 112, initialLayout: "grid")
            Divider()
            printProfileBrowser(height: 240, thumbnailSize: 112, initialLayout: "grid")
        }

        panel(
            "source",
            "Source & Camera",
            systemImage: "camera",
            modified: sourceControlsModified
        ) {
            if imageService.isRAWSource {
                ControlGroupTitle("RAW Development")
                rawFullControls
                Divider()
            }
            cameraFullControls
        }

        panel(
            "film-development",
            "Film Development",
            systemImage: "film",
            modified: filmDevelopmentModified
        ) {
            filmDevelopmentFullControls
        }

        panel(
            "texture",
            "Film Character & Texture",
            systemImage: "camera.filters",
            modified: filmCharacterModified
        ) {
            EffectDisclosure("Halation", isOn: $model.parameters.film.halation.active, defaultIsOn: HalationParameters().active, initiallyExpanded: true) {
                halationFullControls
            }
            EffectDisclosure("Grain", isOn: $model.parameters.film.grain.active, defaultIsOn: GrainParameters().active) {
                grainFullControls
            }
            EffectDisclosure("Film glare", isOn: $model.parameters.film.glare.active, defaultIsOn: GlareParameters().active) {
                glareControls($model.parameters.film.glare)
            }
        }

        panel(
            "print-controls",
            "Enlarger & Print",
            systemImage: "lightbulb",
            modified: printControlsModified
        ) {
            enlargerFullControls
            Divider()
            printFullControls
        }

        panel(
            "scan-output",
            "Scanner & Output",
            systemImage: "scanner",
            modified: scannerOutputModified
        ) {
            ControlGroupTitle("Scanner")
            scannerFullControls
            Divider()
            ControlGroupTitle("I/O & Color")
            ioFullControls
        }

        panel(
            "engine",
            "Engine",
            systemImage: "gearshape.2",
            modified: engineModified
        ) {
            engineFullControls
        }
    }

    // MARK: - Debug / legacy layout

    @ViewBuilder
    private var debugLayout: some View {
        DebugInterfaceBanner()

        if imageService.isRAWSource {
            legacyPanel("debug-raw", "RAW Development", systemImage: "camera.aperture") {
                rawFullControls
            }
        }

        legacyPanel("debug-camera", "Camera", systemImage: "camera") {
            cameraFullControls
        }

        legacyPanel("debug-film", "Film / DIR", systemImage: "film") {
            filmProfileBrowser(height: 455, thumbnailSize: 128, initialLayout: "list")
            Divider()
            filmDevelopmentFullControls
        }

        legacyPanel("debug-halation", "Halation", systemImage: "sun.max") {
            ParameterToggle("Enabled", isOn: $model.parameters.film.halation.active, defaultValue: HalationParameters().active)
            if model.parameters.film.halation.active {
                halationFullControls
            }
        }

        legacyPanel("debug-grain", "Grain", systemImage: "circle.grid.cross") {
            ParameterToggle("Enabled", isOn: $model.parameters.film.grain.active, defaultValue: GrainParameters().active)
            if model.parameters.film.grain.active {
                grainFullControls
            }
        }

        legacyPanel("debug-film-glare", "Film glare", systemImage: "sparkle") {
            GlareEditor(parameters: $model.parameters.film.glare)
        }

        legacyPanel("debug-enlarger", "Enlarger", systemImage: "lightbulb") {
            enlargerFullControls
        }

        legacyPanel("debug-print", "Print", systemImage: "photo.on.rectangle.angled") {
            printProfileBrowser(height: 455, thumbnailSize: 128, initialLayout: "list")
            Divider()
            printFullControls
        }

        legacyPanel("debug-scanner", "Scanner", systemImage: "scanner") {
            scannerFullControls
        }

        legacyPanel("debug-io", "I/O & Color", systemImage: "paintpalette") {
            ioFullControls
        }

        legacyPanel("debug-engine", "Engine", systemImage: "gearshape.2") {
            engineFullControls
            Divider()
            ControlGroupTitle("Preview / performance (debug)")
            engineDebugOnlyControls
        }

        legacyPanel("debug-taps", "Debug / Taps", systemImage: "ladybug") {
            debugFullControls
        }
    }

    // MARK: - Profiles

    private func filmProfileBrowser(height: CGFloat, thumbnailSize: CGFloat, initialLayout: String) -> some View {
        ProfileThumbnailSelector(
            title: "Film profile",
            kind: "film",
            selectedID: profiles.selectedFilmID,
            setSelection: { profiles.selectedFilmID = $0 },
            profiles: profiles.filmProfiles,
            previewImages: previews.filmPreviewImages,
            noneEntry: nil,
            onSelectionChanged: { model.selectedFilmChanged() },
            refresh: { previews.refreshFilmPreviews(parameters: model.parameters) },
            browserHeight: height,
            thumbnailSize: thumbnailSize,
            initialLayout: initialLayout
        )
    }

    private func printProfileBrowser(height: CGFloat, thumbnailSize: CGFloat, initialLayout: String) -> some View {
        ProfileThumbnailSelector(
            title: "Print paper profile",
            kind: "print",
            selectedID: profiles.selectedPrintID,
            setSelection: { profiles.selectedPrintID = $0 },
            profiles: profiles.printProfiles,
            previewImages: previews.printPreviewImages,
            noneEntry: ThumbnailNoneEntry(
                title: "None",
                subtitle: "scan film directly",
                image: previews.printPreviewNoneImage
            ),
            onSelectionChanged: { model.requestRender() },
            refresh: { previews.refreshPrintPreviews(parameters: model.parameters) },
            browserHeight: height,
            thumbnailSize: thumbnailSize,
            initialLayout: initialLayout
        )
    }

    // MARK: - Panel helpers

    private func panel<Content: View>(
        _ id: String,
        _ title: String,
        systemImage: String,
        defaultExpanded: Bool = false,
        modified: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        InspectorPanel(
            id: id,
            title: title,
            systemImage: systemImage,
            expandedID: $expandedPanelID,
            solo: soloPanels,
            defaultExpanded: defaultExpanded,
            modified: modified,
            content: content
        )
    }

    private func legacyPanel<Content: View>(
        _ id: String,
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        InspectorPanel(
            id: id,
            title: title,
            systemImage: systemImage,
            expandedID: $expandedPanelID,
            solo: false,
            defaultExpanded: true,
            modified: false,
            content: content
        )
    }

    // MARK: - Modification indicators

    private var quickAdjustmentsModified: Bool {
        lightControlsModified ||
        model.parameters.film.halation != HalationParameters() ||
        model.parameters.film.grain != GrainParameters() ||
        model.parameters.scanner.unsharpAmount != ScannerParameters().unsharpAmount ||
        model.parameters.io.scanFilm != IOParameters().scanFilm ||
        model.parameters.io.colorPositive != IOParameters().colorPositive
    }

    private var lightControlsModified: Bool {
        (imageService.isRAWSource && imageService.rawAdjustments != .default) ||
        model.parameters.camera.exposureCompensationEV != CameraParameters().exposureCompensationEV ||
        model.parameters.camera.autoExposure != CameraParameters().autoExposure ||
        model.parameters.film.densityCurveGamma != FilmRenderingParameters().densityCurveGamma ||
        model.parameters.enlarger.printExposure != EnlargerParameters().printExposure ||
        model.parameters.enlarger.normalizePrintExposure != EnlargerParameters().normalizePrintExposure
    }

    private var sourceControlsModified: Bool {
        (imageService.isRAWSource && imageService.rawAdjustments != .default) ||
        model.parameters.camera != CameraParameters()
    }

    private var filmDevelopmentModified: Bool {
        model.parameters.film.densityCurveGamma != FilmRenderingParameters().densityCurveGamma ||
        model.parameters.film.dirCouplers != DIRCouplersParameters()
    }

    private var filmCharacterModified: Bool {
        model.parameters.film.halation != HalationParameters() ||
        model.parameters.film.grain != GrainParameters() ||
        model.parameters.film.glare != GlareParameters() ||
        model.parameters.camera.filmFormatMillimeters != CameraParameters().filmFormatMillimeters
    }

    private var detailControlsModified: Bool {
        model.parameters.camera.lensBlurMicrometers != CameraParameters().lensBlurMicrometers ||
        model.parameters.scanner != ScannerParameters()
    }

    private var outputControlsModified: Bool {
        model.parameters.io.outputColorSpace != IOParameters().outputColorSpace ||
        model.parameters.io.outputCCTFEncoding != IOParameters().outputCCTFEncoding ||
        model.parameters.io.scanFilm != IOParameters().scanFilm ||
        model.parameters.io.colorPositive != IOParameters().colorPositive
    }

    private var printControlsModified: Bool {
        model.parameters.enlarger != EnlargerParameters() ||
        model.parameters.print != PrintRenderingParameters()
    }

    private var scannerOutputModified: Bool {
        model.parameters.scanner != ScannerParameters() ||
        model.parameters.io != IOParameters()
    }

    private var engineModified: Bool {
        model.parameters.settings != SettingsParameters()
    }
}
#endif
