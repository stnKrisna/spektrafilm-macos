#if os(macOS)
import AppKit
import SwiftUI
import SpektrafilmCore

struct ContentView: View {
    @EnvironmentObject var model: AppViewModel
    @EnvironmentObject var profiles: ProfileService
    @EnvironmentObject var imageService: ImageService
    @EnvironmentObject var renderService: RenderService
    @State private var showingExportSheet = false
    @State private var exportSettings = ExportSettings()
    @State private var pendingExportSettings: ExportSettings?
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                PreviewPane().frame(minWidth: 500)
                Inspector()
                    .frame(minWidth: 360, idealWidth: 360, maxWidth: 500)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Divider()
            HStack {
                if renderService.isRendering {
                    if let progress = renderService.renderProgress {
                        ProgressView(value: progress).controlSize(.small).frame(maxWidth: 160)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button { renderService.cancelRender() } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel the current render")
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("status.text")
                Spacer()
            }.padding(.horizontal, 10).frame(height: 30)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open Image", systemImage: "photo") { imageService.openImage() }.help("Open a photograph")
                    .accessibilityIdentifier("toolbar.openImage")
                Button("Profiles", systemImage: "folder") { profiles.chooseProfileDirectory() }.help("Choose profile folder")
                    .accessibilityIdentifier("toolbar.profiles")
                if !model.livePreview {
                    Button("Render", systemImage: "sparkles") { model.renderImmediately() }.help("Render preview").disabled(imageService.sourceImage == nil || profiles.selectedFilm == nil)
                        .accessibilityIdentifier("toolbar.render")
                }
                Button("Export", systemImage: "square.and.arrow.up") { showingExportSheet = true }.help("Export full-resolution image").disabled(renderService.previewImage == nil)
                    .accessibilityIdentifier("toolbar.export")
            }
        }
        .sheet(isPresented: $showingExportSheet, onDismiss: {
            // NSSavePanel must not be created while SwiftUI is still tearing down
            // the export configuration sheet. `onDismiss` runs after that sheet has
            // actually been detached, unlike a yielded Task from the button action.
            guard let settings = pendingExportSettings else { return }
            pendingExportSettings = nil
            model.exportService.exportImage(settings: settings, parameters: model.parameters)
        }) {
            ExportSheet(
                settings: $exportSettings,
                onCancel: {
                    pendingExportSettings = nil
                    showingExportSheet = false
                },
                onContinue: { settings in
                    pendingExportSettings = settings
                    showingExportSheet = false
                }
            )
        }
        .task { model.bootstrapUITestIfNeeded() }
    }
}
#endif
