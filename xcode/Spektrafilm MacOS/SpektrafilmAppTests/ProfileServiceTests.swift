//
//  ProfileServiceTests.swift
//  SpektrafilmAppTests
//

import Foundation
import Testing
import SpektrafilmCore
@testable import SpektrafilmApp

@MainActor
struct ProfileServiceTests {

    // MARK: - Fixtures

    private func makeProfile(
        id: String,
        stage: String?,
        support: String? = nil,
        targetPrint: String? = nil
    ) throws -> FilmProfile {
        var info: [String: Any] = ["stock": id]
        if let stage { info["stage"] = stage }
        if let support { info["support"] = support }
        if let targetPrint { info["target_print"] = targetPrint }
        let object: [String: Any] = ["metadata": [:], "info": info, "data": [:]]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(FilmProfile.self, from: data)
    }

    // MARK: - Filtering & selection

    @Test func loadProfilesFiltersFilmAndPrintAndSelectsDefaults() throws {
        let loader = FakeProfileLoader()
        loader.defaultProfiles = [
            try makeProfile(id: "film-a", stage: "filming"),
            try makeProfile(id: "film-b", stage: "filming"),
            try makeProfile(id: "paper-x", stage: "printing"),
            try makeProfile(id: "paper-y", stage: "printing"),
            try makeProfile(id: "scanner", stage: "scanning")
        ]
        let delegate = SpyProfileServiceDelegate()
        let service = ProfileService(loader: loader, picker: FakeDirectoryPicker())
        service.delegate = delegate

        service.loadProfiles(at: URL(fileURLWithPath: "/tmp/spektrafilm-test"))

        #expect(service.filmProfiles.map(\.id) == ["film-a", "film-b"])
        #expect(service.printProfiles.map(\.id) == ["paper-x", "paper-y"])
        #expect(service.selectedFilmID == "film-a")
        #expect(service.selectedPrintID == "paper-x")
        #expect(delegate.loadedCounts == [5])
        #expect(delegate.errors.isEmpty)
    }

    @Test func honorsTargetPrintWhenPresent() throws {
        let loader = FakeProfileLoader()
        loader.defaultProfiles = [
            try makeProfile(id: "film-a", stage: "filming", targetPrint: "paper-y"),
            try makeProfile(id: "paper-x", stage: "printing"),
            try makeProfile(id: "paper-y", stage: "printing")
        ]
        let service = ProfileService(loader: loader, picker: FakeDirectoryPicker())

        service.loadProfiles(at: URL(fileURLWithPath: "/tmp/spektrafilm-test"))

        #expect(service.selectedFilmID == "film-a")
        #expect(service.selectedPrintID == "paper-y")
    }

    @Test func fallsBackToFirstPrintWhenTargetMissing() throws {
        let loader = FakeProfileLoader()
        loader.defaultProfiles = [
            try makeProfile(id: "film-a", stage: "filming", targetPrint: "does-not-exist"),
            try makeProfile(id: "paper-x", stage: "printing"),
            try makeProfile(id: "paper-y", stage: "printing")
        ]
        let service = ProfileService(loader: loader, picker: FakeDirectoryPicker())

        service.loadProfiles(at: URL(fileURLWithPath: "/tmp/spektrafilm-test"))

        #expect(service.selectedPrintID == "paper-x")
    }

    // MARK: - Error handling

    @Test func reportsLoadFailureToDelegate() throws {
        let loader = FakeProfileLoader()
        loader.loadError = FakeProfileError.boom
        let delegate = SpyProfileServiceDelegate()
        let service = ProfileService(loader: loader, picker: FakeDirectoryPicker())
        service.delegate = delegate

        service.loadProfiles(at: URL(fileURLWithPath: "/tmp/spektrafilm-test"))

        #expect(delegate.loadedCounts.isEmpty)
        #expect(delegate.errors.count == 1)
        #expect(service.pipelineResources == nil)
    }

    @Test func reportsMissingBundledData() {
        let loader = FakeProfileLoader()
        loader.bundledURL = nil
        let delegate = SpyProfileServiceDelegate()
        let service = ProfileService(loader: loader, picker: FakeDirectoryPicker())
        service.delegate = delegate

        service.loadBundledProfiles()

        #expect(delegate.noBundledCount == 1)
        #expect(delegate.loadedCounts.isEmpty)
    }

    @Test func loadBundledProfilesUsesBundledURL() throws {
        let loader = FakeProfileLoader()
        let bundled = URL(fileURLWithPath: "/tmp/spektrafilm-bundle")
        loader.bundledURL = bundled
        loader.defaultProfiles = [try makeProfile(id: "film-a", stage: "filming")]
        let delegate = SpyProfileServiceDelegate()
        let service = ProfileService(loader: loader, picker: FakeDirectoryPicker())
        service.delegate = delegate

        service.loadBundledProfiles()

        #expect(loader.loadedDirectories == [bundled])
        #expect(delegate.loadedCounts == [1])
    }

    // MARK: - Directory picker

    @Test func chooseDirectoryLoadsChosenURL() throws {
        let loader = FakeProfileLoader()
        loader.defaultProfiles = [try makeProfile(id: "film-a", stage: "filming")]
        let picker = FakeDirectoryPicker()
        let chosen = URL(fileURLWithPath: "/tmp/spektrafilm-chosen")
        picker.url = chosen
        let service = ProfileService(loader: loader, picker: picker)

        service.chooseProfileDirectory()

        #expect(loader.loadedDirectories == [chosen])
    }

    @Test func chooseDirectoryCancelledDoesNotLoad() {
        let loader = FakeProfileLoader()
        let picker = FakeDirectoryPicker()
        picker.url = nil
        let service = ProfileService(loader: loader, picker: picker)

        service.chooseProfileDirectory()

        #expect(loader.loadedDirectories.isEmpty)
    }
}

// MARK: - Fakes

private enum FakeProfileError: Error { case boom }

private final class FakeProfileLoader: ProfileLoading {
    var bundledURL: URL?
    var defaultProfiles: [FilmProfile] = []
    var loadError: Error?
    private(set) var loadedDirectories: [URL] = []

    func loadResources(dataDirectory: URL) throws -> PipelineResources {
        throw FakeProfileError.boom
    }

    func loadProfiles(from directory: URL) throws -> [FilmProfile] {
        loadedDirectories.append(directory)
        if let loadError { throw loadError }
        return defaultProfiles
    }

    func bundledDataURL() -> URL? { bundledURL }
}

@MainActor
private final class FakeDirectoryPicker: ProfileDirectoryPicking {
    var url: URL?
    func chooseDirectory() -> URL? { url }
}

@MainActor
private final class SpyProfileServiceDelegate: ProfileServiceDelegate {
    var loadedCounts: [Int] = []
    var errors: [Error] = []
    var noBundledCount = 0

    func profileService(_ service: ProfileService, didLoadProfiles totalCount: Int) {
        loadedCounts.append(totalCount)
    }

    func profileService(_ service: ProfileService, didFailWith error: Error) {
        errors.append(error)
    }

    func profileServiceDidFindNoBundledProfiles(_ service: ProfileService) {
        noBundledCount += 1
    }
}
