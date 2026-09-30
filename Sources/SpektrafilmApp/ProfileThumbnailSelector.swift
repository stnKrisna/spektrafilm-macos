#if os(macOS)
import AppKit
import SwiftUI
import SpektrafilmCore

struct ThumbnailNoneEntry {
    let title: String
    let subtitle: String
    let image: NSImage?
}

struct ProfileThumbnailSelector: View {
    let title: String
    let kind: String
    let selectedID: String?
    let setSelection: (String?) -> Void
    let profiles: [FilmProfile]
    let previewImages: [NSImage?]
    let noneEntry: ThumbnailNoneEntry?
    let onSelectionChanged: () -> Void
    let refresh: () -> Void
    let browserHeight: CGFloat
    let thumbnailSize: CGFloat

    @State private var layoutMode: String

    private static let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    init(
        title: String,
        kind: String,
        selectedID: String?,
        setSelection: @escaping (String?) -> Void,
        profiles: [FilmProfile],
        previewImages: [NSImage?],
        noneEntry: ThumbnailNoneEntry?,
        onSelectionChanged: @escaping () -> Void,
        refresh: @escaping () -> Void,
        browserHeight: CGFloat = 320,
        thumbnailSize: CGFloat = 112,
        initialLayout: String = "grid"
    ) {
        self.title = title
        self.kind = kind
        self.selectedID = selectedID
        self.setSelection = setSelection
        self.profiles = profiles
        self.previewImages = previewImages
        self.noneEntry = noneEntry
        self.onSelectionChanged = onSelectionChanged
        self.refresh = refresh
        self.browserHeight = browserHeight
        self.thumbnailSize = thumbnailSize
        self._layoutMode = State(initialValue: initialLayout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $layoutMode) {
                    Image(systemName: "list.bullet").tag("list")
                    Image(systemName: "square.grid.2x2").tag("grid")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 88)
                .accessibilityIdentifier("profiles.\(kind).layout")
            }

            ScrollView {
                if layoutMode == "list" {
                    listMode
                } else {
                    gridMode
                }
            }
            .frame(height: browserHeight)
            .accessibilityIdentifier("profiles.\(kind).browser")
        }
        .onChange(of: selectedID) { _, _ in onSelectionChanged() }
        .task { refresh() }
    }

    private var listMode: some View {
        LazyVStack(spacing: 4) {
            if let noneEntry {
                listRow(
                    title: noneEntry.title,
                    subtitle: noneEntry.subtitle,
                    image: noneEntry.image,
                    selected: selectedID == nil,
                    identifier: "profile.\(kind).none"
                ) {
                    setSelection(nil)
                }
            }

            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                listRow(
                    title: profile.info.name ?? profile.id,
                    subtitle: profile.id,
                    image: index < previewImages.count ? previewImages[index] : nil,
                    selected: selectedID == profile.id,
                    identifier: "profile.\(kind).\(profile.id)"
                ) {
                    setSelection(profile.id)
                }
            }
        }
    }

    private func listRow(
        title: String,
        subtitle: String,
        image: NSImage?,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PixelThumb(image: image, size: min(thumbnailSize, 92))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        selected ? Color.accentColor : Color.gray.opacity(0.25),
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var gridMode: some View {
        LazyVGrid(columns: Self.columns, spacing: 10) {
            if let noneEntry {
                gridTile(
                    title: noneEntry.title,
                    subtitle: noneEntry.subtitle,
                    image: noneEntry.image,
                    selected: selectedID == nil,
                    identifier: "profile.\(kind).none"
                ) {
                    setSelection(nil)
                }
            }

            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                gridTile(
                    title: profile.info.name ?? profile.id,
                    subtitle: profile.id,
                    image: index < previewImages.count ? previewImages[index] : nil,
                    selected: selectedID == profile.id,
                    identifier: "profile.\(kind).\(profile.id)"
                ) {
                    setSelection(profile.id)
                }
            }
        }
    }

    private func gridTile(
        title: String,
        subtitle: String,
        image: NSImage?,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                PixelThumb(image: image, size: thumbnailSize)
                Text(title).font(.caption).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        selected ? Color.accentColor : Color.gray.opacity(0.25),
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

struct PixelThumb: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.22))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
#endif
