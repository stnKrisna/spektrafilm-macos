#if os(macOS)
import AppKit
import Combine
import Foundation
import SpektrafilmCore

/// Read-only surface other services depend on instead of reaching into
/// `AppViewModel`. Kept separate from the concrete class so tests and future
/// services can substitute a lightweight provider.
@MainActor
protocol ProfileProviding: AnyObject {
    var filmProfiles: [FilmProfile] { get }
    var printProfiles: [FilmProfile] { get }
    var selectedFilmID: String? { get set }
    var selectedPrintID: String? { get set }
    var selectedFilm: FilmProfile? { get }
    var selectedPrint: FilmProfile? { get }
    var pipelineResources: PipelineResources? { get }
    var prewarmTask: Task<(), Never>? { get }
}

/// UI-side reactions to profile loading. `ProfileService` owns no status or
/// preview state itself, which keeps it independently testable.
@MainActor
protocol ProfileServiceDelegate: AnyObject {
    func profileService(_ service: ProfileService, didLoadProfiles totalCount: Int)
    func profileService(_ service: ProfileService, didFailWith error: Error)
    func profileServiceDidFindNoBundledProfiles(_ service: ProfileService)
}

/// Seam over the bundle/filesystem-backed profile and data-pack loaders.
protocol ProfileLoading {
    func loadResources(dataDirectory: URL) throws -> PipelineResources
    func loadProfiles(from directory: URL) throws -> [FilmProfile]
    func bundledDataURL() -> URL?
}

struct LiveProfileLoader: ProfileLoading {
    func loadResources(dataDirectory: URL) throws -> PipelineResources {
        try PipelineResources.load(dataDirectory: dataDirectory)
    }

    func loadProfiles(from directory: URL) throws -> [FilmProfile] {
        try ProfileLibrary.loadDirectory(directory)
    }

    /// Loads the data pack bundled into the app (SwiftPM: `<bundle>/Data`,
    /// Xcode: `Contents/Resources/Data`) so profiles are available at launch.
    /// Falls back to the manual picker when no bundled pack is present.
    func bundledDataURL() -> URL? {
        var candidates: [URL] = []
        #if SWIFT_PACKAGE
        // SwiftPM copies ../Data into the resource bundle beside the generated accessor.
        candidates.append(Bundle.module.bundleURL.appendingPathComponent("Data"))
        #endif
        // Xcode copies Data into the app bundle's Contents/Resources. Bundle.main
        // resolves to the app bundle root regardless of CWD or app-sandbox rewriting.
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Resources")
                .appendingPathComponent("Data")
        )
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("pack.json").path) }
    }
}

/// Seam over the profile directory picker so tests can drive selection without
/// presenting an `NSOpenPanel`.
@MainActor
protocol ProfileDirectoryPicking {
    func chooseDirectory() -> URL?
}

struct LiveProfileDirectoryPicker: ProfileDirectoryPicking {
    func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Owns the loaded film/print profile catalog, the selected pair, and the
/// spectral data pack. Side effects (status text, preview refresh, render) are
/// forwarded to `delegate` rather than performed here.
@MainActor
final class ProfileService: ObservableObject, ProfileProviding {
    @Published private(set) var filmProfiles: [FilmProfile] = []
    @Published private(set) var printProfiles: [FilmProfile] = []
    @Published var selectedFilmID: String?
    @Published var selectedPrintID: String?
    @Published private(set) var pipelineResources: PipelineResources?

    private(set) var prewarmTask: Task<(), Never>?
    private var prewarmGeneration: UInt = 0

    weak var delegate: ProfileServiceDelegate?

    private let loader: ProfileLoading
    private let picker: ProfileDirectoryPicking

    init(loader: ProfileLoading = LiveProfileLoader(),
         picker: ProfileDirectoryPicking = LiveProfileDirectoryPicker()) {
        self.loader = loader
        self.picker = picker
    }

    var selectedFilm: FilmProfile? { filmProfiles.first { $0.id == selectedFilmID } }
    var selectedPrint: FilmProfile? { printProfiles.first { $0.id == selectedPrintID } }

    func chooseProfileDirectory() {
        guard let url = picker.chooseDirectory() else {
            AppLog.info("app", "Profile directory selection cancelled")
            return
        }
        AppLog.info("app", "Chose profile directory: \(url.path)")
        loadProfiles(at: url)
    }

    func loadProfiles(at url: URL) {
        AppLog.info("app", "Loading profiles from \(url.path)")
        do {
            // Upstream layout is Data/{pack.json,spectra_lut.f32,profiles/}.
            // Accept either Data itself or Data/profiles from the picker.
            let dataDir = url.lastPathComponent == "profiles" ? url.deletingLastPathComponent() : url
            if FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("pack.json").path),
               FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("spectra_lut.f32").path) {
                pipelineResources = try loader.loadResources(dataDirectory: dataDir)
                AppLog.info("app", "Loaded spectral data pack from \(dataDir.path)")
            } else {
                pipelineResources = nil
                AppLog.warning("app", "No pack.json/spectra_lut.f32 beside profiles; renderer will use compatibility fallbacks")
            }
            let profileDir = FileManager.default.fileExists(atPath: url.appendingPathComponent("profiles").path) ? url.appendingPathComponent("profiles") : url
            let all = try loader.loadProfiles(from: profileDir)
            filmProfiles = all.filter { ($0.info.stage ?? "filming") == "filming" || ($0.info.support ?? "") == "film" }
            printProfiles = all.filter { ($0.info.stage ?? "") == "printing" || ($0.info.support ?? "") == "paper" }
            AppLog.info("app", "Loaded \(all.count) profiles: \(filmProfiles.count) film, \(printProfiles.count) print")
            selectedFilmID = filmProfiles.first?.id
            if let target = selectedFilm?.info.targetPrint, printProfiles.contains(where: { $0.id == target }) { selectedPrintID = target }
            else { selectedPrintID = printProfiles.first?.id }
            AppLog.debug("app", "Auto-selected film=\(selectedFilmID ?? "nil"), print=\(selectedPrintID ?? "nil")")
            if let target = selectedFilm?.info.targetPrint, !printProfiles.contains(where: { $0.id == target }), let print = selectedPrint {
                AppLog.warning("app", "Film '\(selectedFilm?.id ?? "?")' targets print '\(target)' but it is not loaded; using '\(print.id)' instead")
            }
            startTCLUTPrewarm()
            delegate?.profileService(self, didLoadProfiles: all.count)
        } catch {
            AppLog.error("app", "Profile load failed at \(url.path): \(error)")
            delegate?.profileService(self, didFailWith: error)
        }
    }

    func loadBundledProfiles() {
        guard let dataURL = loader.bundledDataURL() else {
            AppLog.warning("app", "No bundled Data found; use Profiles → Choose Profile Directory…")
            delegate?.profileServiceDidFindNoBundledProfiles(self)
            return
        }
        AppLog.info("app", "Loading bundled profiles from \(dataURL.path)")
        loadProfiles(at: dataURL)
    }

    private func startTCLUTPrewarm() {
        guard let resources = pipelineResources else { return }
        let filmSet = filmProfiles
        let printSet = printProfiles
        guard !filmSet.isEmpty || !printSet.isEmpty else { return }
        prewarmTask?.cancel()
        prewarmGeneration &+= 1
        let generation = prewarmGeneration
        prewarmTask = Task.detached(priority: .utility) { [weak self] in
            let warmStart = ContinuousClock.now
            if !filmSet.isEmpty { resources.prewarmTCLUTs(for: filmSet) }
            if !printSet.isEmpty { resources.prewarmTCLUTs(for: printSet) }
            AppLog.info("app", "Startup TC LUT prewarm: \(AppLog.formatElapsed(AppLog.msSince(warmStart)))")
            Task { @MainActor [weak self] in
                guard let self, self.prewarmGeneration == generation else { return }
                self.prewarmTask = nil
            }
        }
    }
}
#endif
