#if os(macOS)
import SwiftUI
import SpektrafilmCore

struct SettingsView: View {
    @EnvironmentObject var model: AppViewModel
    @AppStorage(AdjustmentInterfacePreferences.modeKey)
    private var interfaceModeRaw = AdjustmentInterfacePreferences.defaultMode
    @AppStorage(AdjustmentInterfacePreferences.soloPanelsKey)
    private var soloPanels = true
    @AppStorage(AdjustmentInterfacePreferences.debugModeKey)
    private var debugMode = false
    @AppStorage(AdjustmentInterfacePreferences.compareModeKey)
    private var compareModeRaw = PreviewCompareMode.click.rawValue
    @AppStorage(AdjustmentInterfacePreferences.appearanceKey)
    private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage(AdjustmentInterfacePreferences.previewBackgroundKey)
    private var previewBackgroundRaw = PreviewBackground.gray.rawValue

    private var interfaceMode: AdjustmentInterfaceMode {
        AdjustmentInterfaceMode(rawValue: interfaceModeRaw) ?? .basic
    }

    var body: some View {
        TabView {
            interfaceSettings
                .tabItem { Label("Interface", systemImage: "sidebar.right") }

            previewSettings
                .tabItem { Label("Preview", systemImage: "photo") }

            advanceSettings
                .tabItem { Label("Advance", systemImage: "gearshape.2") }
        }
        .onChange(of: debugMode) { _, isOn in
            if !isOn, interfaceModeRaw == AdjustmentInterfaceMode.debug.rawValue {
                interfaceModeRaw = AdjustmentInterfaceMode.advanced.rawValue
            }
        }
        .padding(20)
        .frame(width: 560, height: 430)
    }

    private var interfaceSettings: some View {
        Form {
            Section("Adjustment Interface") {
                Picker("Layout", selection: $interfaceModeRaw) {
                    ForEach(AdjustmentInterfaceMode.allCases.filter { $0 != .debug || debugMode }) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.interface.layout")

                Text(interfaceMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Changing the interface only changes which controls are visible. Existing render parameters are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Accordion mode", isOn: $soloPanels)
                    .disabled(interfaceMode == .debug)
                    .accessibilityIdentifier("settings.accordion")

                Text("Opening a major panel closes the previously open one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Theme") {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.appearance")

                Picker("Preview background", selection: $previewBackgroundRaw) {
                    ForEach(PreviewBackground.allCases) { background in
                        Text(background.title).tag(background.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.preview.background")

                Text("Preview background is the neutral surround shown behind the photograph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var previewSettings: some View {
        Form {
            Section("Rendering") {
                Toggle("Live preview", isOn: $model.livePreview)
                    .accessibilityIdentifier("settings.livePreview")

                Text("When enabled, adjustments render automatically. When disabled, use the toolbar's Render button to update the preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Comparison") {
                Picker("Compare", selection: $compareModeRaw) {
                    ForEach(PreviewCompareMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.compare")
            }
        }
        .formStyle(.grouped)
    }

    private var advanceSettings: some View {
        Form {
            Section("Debug") {
                Toggle("Debug Mode", isOn: $debugMode)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.debugMode")
                if debugMode {
                    LabeledContent("Reference precision", value: "Double (f64)")
                    LabeledContent("Interactive preview", value: "Metal Float32 (film→print core, CPU front-end)")
                }
            }

            Section("GPU Acceleration") {
                Toggle("Metal preview acceleration", isOn: $model.parameters.settings.useMetalPreview)
                Toggle("Metal export acceleration (Float32)", isOn: $model.parameters.settings.useMetalExport)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
