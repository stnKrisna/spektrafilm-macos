#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case tiff = "TIFF"
    case png = "PNG"

    var id: Self { self }

    var contentType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .png: return .png
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .tiff: return "tif"
        case .png: return "png"
        }
    }

    var supportsSixteenBit: Bool { self != .jpeg }
}

enum ExportBitDepth: Int, CaseIterable, Identifiable, Sendable {
    case eight = 8
    case sixteen = 16

    var id: Int { rawValue }
    var label: String { "\(rawValue)-bit" }
}

enum TIFFCompression: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case lzw = "LZW"
    case deflate = "ZIP / Deflate"

    var id: Self { self }

    /// TIFF Compression tag values from the TIFF specification. Image I/O
    /// consumes these through kCGImagePropertyTIFFCompression.
    var imageIOValue: Int {
        switch self {
        case .none: return 1
        case .lzw: return 5
        case .deflate: return 8
        }
    }
}

struct ExportSettings: Equatable, Sendable {
    var format: ExportFormat = .jpeg
    var bitDepth: ExportBitDepth = .eight
    var jpegQuality: Double = 0.90
    var tiffCompression: TIFFCompression = .lzw
    var pngInterlaced = false

    var effectiveBitDepth: ExportBitDepth {
        format.supportsSixteenBit ? bitDepth : .eight
    }
}

struct ExportSheet: View {
    @Binding var settings: ExportSettings
    let onCancel: () -> Void
    let onContinue: (ExportSettings) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("export.sheet")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Form {
                Section("Format") {
                    Picker("File Format", selection: $settings.format) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("export.format")
                }

                Section("Image") {
                    if settings.format.supportsSixteenBit {
                        Picker("Color Depth", selection: $settings.bitDepth) {
                            ForEach(ExportBitDepth.allCases) { depth in
                                Text(depth.label).tag(depth)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("export.bitDepth")
                    }
                }

                formatSettings
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("export.cancel")
                Button("Continue…") {
                    onContinue(settings)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("export.continue")
            }
            .padding(16)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.2), value: settings.format)
        .onChange(of: settings.format) { _, newFormat in
            if !newFormat.supportsSixteenBit {
                settings.bitDepth = .eight
            }
        }
    }

    @ViewBuilder
    private var formatSettings: some View {
        switch settings.format {
        case .jpeg:
            Section("JPEG Settings") {
                LabeledContent("Quality") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.jpegQuality, in: 0.01...1.0)
                            .frame(width: 190)
                            .accessibilityIdentifier("export.jpeg.quality")
                        Text("\(Int((settings.jpegQuality * 100).rounded()))")
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
        case .tiff:
            Section("TIFF Settings") {
                Picker("Compression", selection: $settings.tiffCompression) {
                    ForEach(TIFFCompression.allCases) { compression in
                        Text(compression.rawValue).tag(compression)
                    }
                }
                .accessibilityIdentifier("export.tiff.compression")
            }
        case .png:
            Section("PNG Settings") {
                Toggle("Interlaced (Adam7)", isOn: $settings.pngInterlaced)
                    .accessibilityIdentifier("export.png.interlaced")
                Text("Interlacing improves progressive display while loading; it does not change image quality.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
