#if os(macOS)
import AppKit
import SwiftUI
import SpektrafilmCore

enum ColorSpaceOptions {
    static let all = ["sRGB", "Display P3", "Adobe RGB", "ProPhoto RGB", "Rec.2020", "ACEScg"]
}

/// Normalizes a human-readable control label into a stable accessibility
/// identifier fragment so UI tests can address any `ParameterSlider`,
/// `ParameterToggle`, `ParameterPicker`, or `EffectDisclosure` instance.
enum AccessibilityID {
    static func sanitized(_ label: String) -> String {
        let allowed = label.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        var collapsed = String(allowed)
        while collapsed.contains("--") { collapsed = collapsed.replacingOccurrences(of: "--", with: "-") }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct InspectorPanel<Content: View>: View {
    let id: String
    let title: String
    let systemImage: String
    @Binding var expandedID: String?
    let solo: Bool
    let modified: Bool
    let content: Content

    @State private var localExpanded: Bool

    init(
        id: String,
        title: String,
        systemImage: String,
        expandedID: Binding<String?>,
        solo: Bool,
        defaultExpanded: Bool = false,
        modified: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self._expandedID = expandedID
        self.solo = solo
        self.modified = modified
        self.content = content()
        self._localExpanded = State(initialValue: defaultExpanded)
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { solo ? expandedID == id : localExpanded },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if solo {
                        if newValue {
                            expandedID = id
                        } else if expandedID == id {
                            expandedID = nil
                        }
                    } else {
                        localExpanded = newValue
                    }
                }
            }
        )
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 9) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                HStack(spacing: 7) {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                        .padding(.leading, 4)
                    Spacer(minLength: 4)
                    if modified {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .help("This group contains non-default adjustments")
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle()) // 1. Defines the entire area as interactive
                .onTapGesture {
                    withAnimation {
                        isExpanded.wrappedValue = !isExpanded.wrappedValue // 2. Triggers the expansion on tap
                    }
                }
            }
            .padding(.horizontal, 4)
            .animation(.easeInOut(duration: 0.2), value: isExpanded.wrappedValue)
        }
        .accessibilityIdentifier("panel.\(id)")
    }
}

struct EffectDisclosure<Content: View>: View {
    let title: String
    @Binding var isOn: Bool
    let defaultIsOn: Bool?
    let content: Content
    @State private var expanded: Bool

    init(
        _ title: String,
        isOn: Binding<Bool>,
        defaultIsOn: Bool? = nil,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self._isOn = isOn
        self.defaultIsOn = defaultIsOn
        self.content = content()
        self._expanded = State(initialValue: initiallyExpanded)
    }

    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { expanded },
            set: { newValue in withAnimation(.easeInOut(duration: 0.2)) { expanded = newValue } }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: expandedBinding) {
            if isOn {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .padding(.top, 6)
                .padding(.leading, 4)
            } else {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        } label: {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                if let defaultIsOn {
                    ParameterResetButton(
                        isDefault: isOn == defaultIsOn,
                        reset: { isOn = defaultIsOn }
                    )
                }
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityIdentifier("toggle.effect.\(AccessibilityID.sanitized(title))")
            }
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.2), value: expanded)
    }
}

struct ControlGroupTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 2)
    }
}

struct DebugInterfaceBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "ladybug.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Debug interface")
                    .font(.callout.weight(.semibold))
                Text("Internal controls, engine settings, and diagnostic taps are visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ParameterResetButton: View {
    let isDefault: Bool
    let reset: () -> Void

    init(isDefault: Bool, reset: @escaping () -> Void) {
        self.isDefault = isDefault
        self.reset = reset
    }

    var body: some View {
        Button(action: reset) {
            Image(systemName: "arrow.counterclockwise")
                .font(.caption2)
                .foregroundStyle(isDefault ? Color.gray.opacity(0.4) : Color.accentColor.opacity(0.85))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .disabled(isDefault)
        .help(isDefault ? "Already at the default value" : "Reset to default value")
    }
}

struct ParameterSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var suffix = ""

    init(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String = "", defaultValue: Double) {
        self.label = label
        self._value = value
        self.range = range
        self.suffix = suffix
        self.defaultValue = defaultValue
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .frame(width: 118, alignment: .leading)
                .lineLimit(1)
                .help(label)
            Slider(value: $value, in: range)
                .controlSize(.small)
                .accessibilityIdentifier("slider.\(AccessibilityID.sanitized(label))")
            Text(formattedValue)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
                .lineLimit(1)
                .accessibilityIdentifier("slider.\(AccessibilityID.sanitized(label)).value")
            ParameterResetButton(
                isDefault: value == defaultValue,
                reset: { value = defaultValue }
            )
            .accessibilityIdentifier("slider.\(AccessibilityID.sanitized(label)).reset")
        }
    }

    private var formattedValue: String {
        String(format: "%.3g", value) + suffix
    }
}

struct ParameterPicker: View {
    let label: String
    @Binding var selection: String
    let options: [String]
    let defaultValue: String

    init(_ label: String, selection: Binding<String>, options: [String], defaultValue: String) {
        self.label = label
        self._selection = selection
        self.options = options
        self.defaultValue = defaultValue
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Picker("", selection: $selection) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 190)
                .accessibilityIdentifier("picker.\(AccessibilityID.sanitized(label))")
                ParameterResetButton(
                    isDefault: selection == defaultValue,
                    reset: { selection = defaultValue }
                )
            }
        }
    }
}

struct ParameterToggle: View {
    let label: String
    @Binding var isOn: Bool
    let defaultValue: Bool

    init(_ label: String, isOn: Binding<Bool>, defaultValue: Bool) {
        self.label = label
        self._isOn = isOn
        self.defaultValue = defaultValue
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle(label, isOn: $isOn)
                .accessibilityIdentifier("toggle.\(AccessibilityID.sanitized(label))")
            ParameterResetButton(
                isDefault: isOn == defaultValue,
                reset: { isOn = defaultValue }
            )
        }
    }
}

struct IntegerStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let defaultValue: Int
    var step: Int = 1

    init(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, defaultValue: Int) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
    }

    var body: some View {
        HStack(spacing: 6) {
            Stepper(value: $value, in: range, step: step) {
                LabeledContent(label, value: "\(value)")
            }
            ParameterResetButton(
                isDefault: value == defaultValue,
                reset: { value = defaultValue }
            )
        }
    }
}

struct UInt64Field: View {
    let label: String
    @Binding var value: UInt64
    let defaultValue: UInt64

    init(_ label: String, value: Binding<UInt64>, defaultValue: UInt64) {
        self.label = label
        self._value = value
        self.defaultValue = defaultValue
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", text: Binding(
                    get: { String(value) },
                    set: { if let parsed = UInt64($0) { value = parsed } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                ParameterResetButton(
                    isDefault: value == defaultValue,
                    reset: { value = defaultValue }
                )
            }
        }
    }
}

struct OptionalStringField: View {
    let label: String
    @Binding var value: String?
    let defaultValue: String?

    init(_ label: String, value: Binding<String?>, defaultValue: String? = nil) {
        self.label = label
        self._value = value
        self.defaultValue = defaultValue
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", text: Binding(
                    get: { value ?? "" },
                    set: { value = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                ParameterResetButton(
                    isDefault: value == defaultValue,
                    reset: { value = defaultValue }
                )
            }
        }
    }
}

struct Vector2Editor: View {
    let title: String
    @Binding var values: [Double]
    let labels: [String]
    let ranges: [ClosedRange<Double>]
    let defaults: [Double]
    var suffix = ""

    init(
        _ title: String,
        values: Binding<[Double]>,
        labels: [String],
        ranges: [ClosedRange<Double>],
        suffix: String = "",
        defaults: [Double]
    ) {
        self.title = title
        self._values = values
        self.labels = labels
        self.ranges = ranges
        self.suffix = suffix
        self.defaults = defaults
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(0..<2, id: \.self) { index in
                ParameterSlider(
                    labels[index],
                    value: arrayBinding(index),
                    range: ranges[index],
                    suffix: suffix,
                    defaultValue: elementDefault(index)
                )
            }
        }
    }

    private func elementDefault(_ index: Int) -> Double {
        index < defaults.count ? defaults[index] : ranges[index].lowerBound
    }

    private func arrayBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { index < values.count ? values[index] : 0 },
            set: { newValue in
                if values.count <= index {
                    values += Array(repeating: 0, count: index - values.count + 1)
                }
                values[index] = newValue
            }
        )
    }
}

struct Vector3Editor: View {
    let title: String
    @Binding var values: [Double]
    let labels: [String]
    let ranges: [ClosedRange<Double>]
    let defaults: [Double]
    var suffix = ""

    init(
        _ title: String,
        values: Binding<[Double]>,
        labels: [String],
        ranges: [ClosedRange<Double>],
        suffix: String = "",
        defaults: [Double]
    ) {
        self.title = title
        self._values = values
        self.labels = labels
        self.ranges = ranges
        self.suffix = suffix
        self.defaults = defaults
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(0..<3, id: \.self) { index in
                ParameterSlider(
                    labels[index],
                    value: arrayBinding(index),
                    range: ranges[index],
                    suffix: suffix,
                    defaultValue: elementDefault(index)
                )
            }
        }
    }

    private func elementDefault(_ index: Int) -> Double {
        index < defaults.count ? defaults[index] : ranges[index].lowerBound
    }

    private func arrayBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { index < values.count ? values[index] : 0 },
            set: { newValue in
                if values.count <= index {
                    values += Array(repeating: 0, count: index - values.count + 1)
                }
                values[index] = newValue
            }
        )
    }
}

struct DiffusionFilterEditor: View {
    let title: String
    @Binding var parameters: DiffusionFilterParameters

    var defaults = DiffusionFilterParameters()

    var body: some View {
        EffectDisclosure(title, isOn: $parameters.active, defaultIsOn: defaults.active) {
            ParameterPicker(
                "Family",
                selection: $parameters.family,
                options: [
                    "black_pro_mist",
                    "pro_mist",
                    "glimmerglass",
                    "pearlescent",
                    "soft_fx",
                    "classic_soft"
                ],
                defaultValue: defaults.family
            )
            ParameterSlider("Strength", value: $parameters.strength, range: 0...2, defaultValue: defaults.strength)
            ParameterSlider("Spatial scale", value: $parameters.spatialScale, range: 0.1...4, defaultValue: defaults.spatialScale)
            ParameterSlider("Halo warmth", value: $parameters.haloWarmth, range: -1...1, defaultValue: defaults.haloWarmth)
            ParameterSlider("Core intensity", value: $parameters.coreIntensity, range: 0...3, defaultValue: defaults.coreIntensity)
            ParameterSlider("Core size", value: $parameters.coreSize, range: 0.1...5, defaultValue: defaults.coreSize)
            ParameterSlider("Halo intensity", value: $parameters.haloIntensity, range: 0...3, defaultValue: defaults.haloIntensity)
            ParameterSlider("Halo size", value: $parameters.haloSize, range: 0.1...8, defaultValue: defaults.haloSize)
            ParameterSlider("Bloom intensity", value: $parameters.bloomIntensity, range: 0...3, defaultValue: defaults.bloomIntensity)
            ParameterSlider("Bloom size", value: $parameters.bloomSize, range: 0.1...12, defaultValue: defaults.bloomSize)
        }
    }
}

struct GlareEditor: View {
    @Binding var parameters: GlareParameters

    var defaults = GlareParameters()

    var body: some View {
        ParameterToggle("Enabled", isOn: $parameters.active, defaultValue: defaults.active)
        if parameters.active {
            ParameterSlider("Percent", value: $parameters.percent, range: 0...0.25, defaultValue: defaults.percent)
            ParameterSlider("Roughness", value: $parameters.roughness, range: 0...2, defaultValue: defaults.roughness)
            ParameterSlider("Blur", value: $parameters.blur, range: 0...5, defaultValue: defaults.blur)
            UInt64Field("Seed", value: $parameters.seed, defaultValue: defaults.seed)
        }
    }
}

struct GamutCompressionEditor: View {
    let title: String
    @Binding var active: Bool
    @Binding var threshold: Double
    @Binding var limit: Double
    @Binding var power: Double

    var body: some View {
        EffectDisclosure(title, isOn: $active, defaultIsOn: true) {
            ParameterSlider("Threshold", value: $threshold, range: 0...2, defaultValue: 0)
            ParameterSlider("Limit", value: $limit, range: 0...4, defaultValue: 1)
            ParameterSlider("Power", value: $power, range: 0.1...4, defaultValue: 6)
        }
    }
}
#endif
