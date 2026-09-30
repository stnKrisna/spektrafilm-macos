#if os(macOS)
import AppKit
import SwiftUI
import SpektrafilmCore

struct FilmFormatOption: Identifiable {
    let id: String
    let label: String
    let longEdgeMm: Double

    init(_ id: String, _ label: String, _ longEdgeMm: Double) {
        self.id = id
        self.label = label
        self.longEdgeMm = longEdgeMm
    }
}

/// Common film formats keyed by the physical long edge of the frame in
/// millimeters — the same number the pipeline uses as `film_format_mm`
/// (`pixel size = filmFormat * 1000 / image long side`). Long edges are
/// unique across the whole list so the dropdown selection maps 1:1 to the
/// `filmFormatMillimeters` value. Formats that share a long edge are merged
/// into a single entry.
private enum FilmFormatOptions {
    static let photography: [FilmFormatOption] = [
        FilmFormatOption("110", "110 Pocket Instamatic", 17),
        FilmFormatOption("aps", "APS / IX240", 30.2),
        FilmFormatOption("126", "126 Instamatic", 26.5),
        FilmFormatOption("135", "135 (35 mm full-frame)", 35),
        FilmFormatOption("135-short", "135 half-frame / square / Stereo 35", 24),
        FilmFormatOption("135-pano", "135 panoramic (XPan)", 65),
        FilmFormatOption("828", "828 Bantam", 40),
        FilmFormatOption("127", "127 Vest Pocket", 60),
    ]

    /// Everything from the "Medium format" row downward in the photography
    /// table is marked as medium format film.
    static let mediumFormat: [FilmFormatOption] = [
        FilmFormatOption("645-6x6", "120/220 6×4.5 / 6×6", 56),
        FilmFormatOption("6x7", "120/220 6×7", 70),
        FilmFormatOption("6x8", "120/220 6×8", 77),
        FilmFormatOption("6x9", "120/220 6×9", 84),
        FilmFormatOption("6x12", "120 6×12 panoramic", 118),
        FilmFormatOption("6x17", "120 6×17 panoramic", 168),
        FilmFormatOption("6x24", "120 6×24 panoramic", 224),
        FilmFormatOption("620", "620 Six-20", 90),
        FilmFormatOption("116-616", "116 / 616 Six-16", 110),
        FilmFormatOption("disc", "Disc", 10),
    ]

    static let largeFormat: [FilmFormatOption] = [
        FilmFormatOption("2.25x3.25", "2¼ × 3¼ in", 83),
        FilmFormatOption("3.25x4.25", "3¼ × 4¼ in", 108),
    ]

    static let cinema: [FilmFormatOption] = [
        FilmFormatOption("r8", "8 mm / Standard 8", 4.8),
        FilmFormatOption("s8", "Super 8", 6.3),
        FilmFormatOption("single8", "Single-8", 5.69),
        FilmFormatOption("ds8", "Double Super 8", 6.22),
        FilmFormatOption("9.5", "9.5 mm Pathé Baby", 8.5),
        FilmFormatOption("16", "16 mm Standard", 10.26),
        FilmFormatOption("u16", "Ultra 16", 11.66),
        FilmFormatOption("s16", "Super 16", 12.52),
        FilmFormatOption("17.5", "17.5 mm (approx.)", 17.5),
        FilmFormatOption("22-28", "22 mm / 28 mm historical (approx.)", 18),
        FilmFormatOption("35-4perf", "35 mm 4-perf / anamorphic / Techniscope", 22),
        FilmFormatOption("s35", "Super 35 (2/3/4-perf)", 24.89),
        FilmFormatOption("vistavision", "VistaVision", 36),
        FilmFormatOption("65-5perf", "65 mm 5-perf / 70 mm print", 52.5),
        FilmFormatOption("65-8perf", "65 mm 8-perf (Dynavision)", 51.6),
        FilmFormatOption("imax", "IMAX 15/70 / OMNIMAX", 70.4),
    ]

    static var all: [FilmFormatOption] { photography + mediumFormat + largeFormat + cinema }

    static func option(for value: Double) -> FilmFormatOption? {
        all.first { abs($0.longEdgeMm - value) < 1e-9 }
    }
}

/// Film-format selector: a dropdown of common formats whose values map
/// directly onto `filmFormatMillimeters`, plus a "Custom…" entry that reveals
/// a plain slider. Selecting a preset snaps the value to that format's long
/// edge; choosing Custom (or dragging the slider off a preset value) keeps
/// the dropdown on Custom until another preset is picked.
struct FilmFormatControl: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double

    @State private var customMode = false

    init(_ label: String = "Film format", value: Binding<Double>, range: ClosedRange<Double> = 4...230, defaultValue: Double = CameraParameters().filmFormatMillimeters) {
        self.label = label
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
    }

    private var isCustom: Bool { customMode || FilmFormatOptions.option(for: value) == nil }

    private var selection: Binding<String> {
        Binding(
            get: {
                if customMode { return "custom" }
                return FilmFormatOptions.option(for: value)?.id ?? "custom"
            },
            set: { newValue in
                if newValue == "custom" {
                    customMode = true
                    return
                }
                customMode = false
                if let option = FilmFormatOptions.all.first(where: { $0.id == newValue }) {
                    value = option.longEdgeMm
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.callout)
                    .frame(width: 118, alignment: .leading)
                    .lineLimit(1)
                    .help(label)
                Picker("", selection: selection) {
                    Text("Still-photography Format").selectionDisabled(true)
                    ForEach(FilmFormatOptions.photography) { Text($0.label).tag($0.id) }
                    Text("Medium Format").selectionDisabled(true)
                    ForEach(FilmFormatOptions.mediumFormat) { Text($0.label).tag($0.id) }
                    Text("Large Format").selectionDisabled(true)
                    ForEach(FilmFormatOptions.largeFormat) { Text($0.label).tag($0.id) }
                    Text("Cinema").selectionDisabled(true)
                    ForEach(FilmFormatOptions.cinema) { Text($0.label).tag($0.id) }
                    Divider()
                    Text("Custom…").tag("custom")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 190)
                ParameterResetButton(
                    isDefault: !customMode && value == defaultValue,
                    reset: { customMode = false; value = defaultValue }
                )
            }
            if isCustom {
                HStack(spacing: 8) {
                    Text("Custom length")
                        .font(.callout)
                        .frame(width: 118, alignment: .leading)
                        .lineLimit(1)
                        .help("Long edge of the film format in millimeters")
                    Slider(value: $value, in: range)
                        .controlSize(.small)
                    Text(String(format: "%.3g", value) + " mm")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                        .lineLimit(1)
                    ParameterResetButton(
                        isDefault: value == defaultValue,
                        reset: { value = defaultValue }
                    )
                }
            }
        }
    }
}
#endif
