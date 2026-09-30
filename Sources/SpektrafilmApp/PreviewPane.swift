#if os(macOS)
import AppKit
import SwiftUI
import SpektrafilmCore

struct PreviewPane: View {
    @EnvironmentObject var model: AppViewModel
    @EnvironmentObject var imageService: ImageService
    @EnvironmentObject var renderService: RenderService
    @EnvironmentObject var viewport: ViewportService
    // nil means Fit. Non-nil is absolute image scale where 1 == 100% / 1:1.
    @State private var zoomScale: CGFloat? = nil
    @AppStorage(AdjustmentInterfacePreferences.compareModeKey)
    private var compareModeRaw = PreviewCompareMode.click.rawValue
    @AppStorage(AdjustmentInterfacePreferences.previewBackgroundKey)
    private var previewBackgroundRaw = PreviewBackground.gray.rawValue
    @State private var sliderComparisonActive = false

    private let zoomSteps: [CGFloat] = [0.05, 0.10, 0.125, 0.25, 0.3333, 0.50, 0.6667, 1, 1.5, 2, 3, 4, 8, 16]

    private var compareMode: PreviewCompareMode {
        PreviewCompareMode(rawValue: compareModeRaw) ?? .click
    }

    private var previewBackground: PreviewBackground {
        PreviewBackground(rawValue: previewBackgroundRaw) ?? .gray
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // A loaded photo keeps the user-chosen neutral assessment surround,
            // which stays neutral regardless of app theme. When nothing is
            // loaded, the placeholder follows the app color theme.
            if let image = model.showOriginal ? imageService.originalPreview : renderService.previewImage ?? imageService.originalPreview {
                ZoomablePreviewView(
                    image: image,
                    sourcePixelSize: imageService.sourcePixelSize,
                    detailTiles: viewport.detailPreviewTiles,
                    comparisonImage: imageService.originalPreview,
                    comparisonSliderActive: compareMode == .beforeAfterSlider && sliderComparisonActive,
                    backgroundColor: previewBackground.nsColor,
                    requestedScale: $zoomScale,
                    onGeometryChanged: { geometry in
                        viewport.requestViewportPreview(geometry, rendered: !model.showOriginal, parameters: model.parameters)
                    }
                )
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .overlay {
                        ContentUnavailableView("No Image", systemImage: "photo", description: Text("Open a photograph to begin."))
                    }
            }

            if renderService.previewImage != nil || imageService.originalPreview != nil {
                zoomControls
                    .padding(10)

                compareToggle
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            if renderService.isRendering {
                VStack(spacing: 6) {
                    if let progress = renderService.renderProgress {
                        ProgressView(value: progress).frame(maxWidth: 220)
                    } else {
                        ProgressView()
                    }
                    Button { renderService.cancelRender() } label: { Text("Cancel Render").font(.caption) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("render.cancel")
                }
                .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(true)
            }
        }
        .clipped()
        .onChange(of: compareModeRaw) { _, _ in
            sliderComparisonActive = false
            model.showOriginal = false
        }
        .onChange(of: model.showOriginal) { _, newValue in
            viewport.compareModeDidChange(showOriginal: newValue, parameters: model.parameters)
        }
        .onChange(of: sliderComparisonActive) { _, newValue in
            viewport.setComparisonSliderActive(newValue, parameters: model.parameters)
        }
        .onChange(of: imageService.sourceImageRevision) { _, _ in
            // A newly opened source should begin in Fit just like Lightroom,
            // while ordinary live renders preserve the inspection viewport.
            zoomScale = nil
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                zoomOut()
            } label: {
                Image(systemName: "minus")
            }
            .help("Zoom out (−)")
            .accessibilityIdentifier("preview.zoomOut")

            Button {
                zoomScale = nil
            } label: {
                Text("Fit").frame(minWidth: 26)
            }
            .help("Fit image to preview (F)")
            .accessibilityIdentifier("preview.fit")

            Button {
                zoomScale = 1
            } label: {
                Text("1:1").frame(minWidth: 28)
            }
            .help("View at 100% / one image pixel per point (1)")
            .accessibilityIdentifier("preview.oneToOne")

            Text(zoomLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
                .accessibilityIdentifier("preview.zoomLabel")

            Button {
                zoomIn()
            } label: {
                Image(systemName: "plus")
            }
            .help("Zoom in (+)")
            .accessibilityIdentifier("preview.zoomIn")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .help("Scroll/pinch to zoom · drag to pan · double-click Fit/100% · middle-click Fit/100%/200%")
    }

    private struct HoldToPreviewButtonStyle: ButtonStyle {
        let enabled: Bool
        @Binding var showOriginal: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onChange(of: configuration.isPressed) { _, isPressed in
                    guard enabled else { return }
                    showOriginal = isPressed
                }
        }
    }
    
    private func getCompareHelpMessage(compareMode: PreviewCompareMode) -> String {
        switch compareMode {
        case .click: return "Click to compare with the original";
        case .hold: return "Hold to compare with the original";
        case .beforeAfterSlider: return "Toggle the draggable before/after comparison slider";
        }
    }

    private var compareToggle: some View {
        Button(
            (compareMode == .beforeAfterSlider && sliderComparisonActive) || model.showOriginal ? "Show Render" : "Compare",
            systemImage: "rectangle.split.2x1"
        ) {
            switch compareMode {
            case .click:
                model.showOriginal.toggle()
            case .beforeAfterSlider:
                model.showOriginal = false
                sliderComparisonActive.toggle()
            case .hold:
                break
            }
        }
        .buttonStyle(
            HoldToPreviewButtonStyle(
                enabled: compareMode == .hold,
                showOriginal: $model.showOriginal
            )
        )
        .controlSize(.small)
        .help(getCompareHelpMessage(compareMode: compareMode))
        .accessibilityIdentifier("preview.compare")
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 7)
        )
    }

    private var zoomLabel: String {
        guard let zoomScale else { return "Fit" }
        let percent = zoomScale * 100
        if percent >= 100 { return String(format: "%.0f%%", percent) }
        if percent >= 10 { return String(format: "%.0f%%", percent) }
        return String(format: "%.1f%%", percent)
    }

    private func zoomIn() {
        if let current = zoomScale {
            zoomScale = zoomSteps.first(where: { $0 > current * 1.001 }) ?? zoomSteps.last
        } else {
            zoomScale = 1
        }
    }

    private func zoomOut() {
        if let current = zoomScale {
            zoomScale = zoomSteps.last(where: { $0 < current * 0.999 }) ?? zoomSteps.first
        } else {
            zoomScale = 0.5
        }
    }
}
#endif
