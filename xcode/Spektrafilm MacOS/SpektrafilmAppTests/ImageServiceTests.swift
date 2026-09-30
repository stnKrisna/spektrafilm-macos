//
//  ImageServiceTests.swift
//  SpektrafilmAppTests
//

import AppKit
import Foundation
import Testing
import SpektrafilmCore
@testable import SpektrafilmApp

@MainActor
struct ImageServiceTests {

    private let url = URL(fileURLWithPath: "/tmp/spektrafilm-image.tif")

    private func makeService(
        decoder: FakeImageDecoder? = nil,
        picker: FakeImagePicker? = nil,
        platform: FakeImageSourcePlatform? = nil,
        delegate: SpyImageServiceDelegate? = nil
    ) -> (ImageService, FakeImagePicker, FakeImageSourcePlatform, SpyImageServiceDelegate) {
        let decoder = decoder ?? FakeImageDecoder()
        let picker = picker ?? FakeImagePicker()
        let platform = platform ?? FakeImageSourcePlatform()
        let delegate = delegate ?? SpyImageServiceDelegate()
        let service = ImageService(decoder: decoder, picker: picker, platform: platform)
        service.delegate = delegate
        return (service, picker, platform, delegate)
    }

    // MARK: - Opening a non-RAW source

    @Test func opensNonRAWSourceAndNotifiesDelegate() throws {
        var decoder = FakeImageDecoder()
        decoder.rawDefaultsResult = nil
        decoder.info = ImageCodec.ImageInfo(width: 640, height: 480)
        decoder.thumbnail = LinearRGBImage(width: 4, height: 3, repeating: 0.5)
        let picker = FakeImagePicker()
        picker.url = url
        let (service, _, platform, delegate) = makeService(decoder: decoder, picker: picker)
        delegate.previewMaxSize = 1024

        service.openImage()

        #expect(service.sourceURL == url)
        #expect(service.isRAWSource == false)
        #expect(service.rawAdjustments == .default)
        #expect(service.sourcePixelSize == CGSize(width: 640, height: 480))
        #expect(service.sourceImage?.width == 4)
        #expect(service.sourceImage?.height == 3)
        #expect(service.sourceImageRevision == 1)
        #expect(service.cachedPreviewMaxSize == 1024)
        #expect(service.cachedPreviewSource?.width == 4)
        #expect(platform.purgeCount == 1)
        #expect(delegate.loadedSourceCount == 1)
        #expect(delegate.failures.isEmpty)
    }

    @Test func openCancelledLeavesStateUntouched() {
        let picker = FakeImagePicker()
        picker.url = nil
        let (service, _, platform, delegate) = makeService(picker: picker)

        service.openImage()

        #expect(service.sourceImage == nil)
        #expect(service.sourceURL == nil)
        #expect(platform.purgeCount == 0)
        #expect(delegate.loadedSourceCount == 0)
    }

    @Test func openFailureReportsToDelegate() {
        var decoder = FakeImageDecoder()
        decoder.shouldFailInspect = true
        let picker = FakeImagePicker()
        picker.url = url
        let (service, _, _, delegate) = makeService(decoder: decoder, picker: picker)

        service.openImage()

        #expect(service.sourceImage == nil)
        #expect(delegate.loadedSourceCount == 0)
        #expect(delegate.failures.count == 1)
        #expect(delegate.failures.first?.1 == .openingSource)
    }

    // MARK: - Opening a RAW source

    @Test func opensRAWSourceAndAdoptsCameraDefaults() throws {
        var decoder = FakeImageDecoder()
        let defaults = RAWAdjustments(exposureEV: 0.5, temperature: 5200, tint: 12, lensCorrectionEnabled: false)
        decoder.rawDefaultsResult = ImageCodec.RAWDefaults(
            info: ImageCodec.ImageInfo(width: 800, height: 600),
            adjustments: defaults
        )
        decoder.rawImage = LinearRGBImage(width: 8, height: 6, repeating: 0.25)
        let picker = FakeImagePicker()
        picker.url = url
        let (service, _, _, delegate) = makeService(decoder: decoder, picker: picker)

        service.openImage()

        #expect(service.isRAWSource == true)
        #expect(service.rawAdjustments == defaults)
        #expect(service.sourcePixelSize == CGSize(width: 800, height: 600))
        #expect(service.sourceImage?.width == 8)
        #expect(delegate.loadedSourceCount == 1)
    }

    @Test func resetRAWAdjustmentsRestoresCameraDefaults() {
        var decoder = FakeImageDecoder()
        let defaults = RAWAdjustments(exposureEV: 0.7, temperature: 4800, tint: -5, lensCorrectionEnabled: true)
        decoder.rawDefaultsResult = ImageCodec.RAWDefaults(
            info: ImageCodec.ImageInfo(width: 10, height: 10),
            adjustments: defaults
        )
        let (service, _, _, _) = makeService(decoder: decoder)
        service.isRAWSource = true
        service.sourceURL = url
        service.rawAdjustments = RAWAdjustments(exposureEV: -1, temperature: 9000, tint: 40, lensCorrectionEnabled: false)

        service.resetRAWAdjustments()

        #expect(service.rawAdjustments == defaults)
    }

    // MARK: - RAW proxy re-development

    @Test func rawAdjustmentIsIgnoredForNonRAWSource() {
        let (service, _, _, delegate) = makeService()

        service.rawAdjustmentsChanged()

        #expect(delegate.willAdjustRAWCount == 0)
        #expect(delegate.updateRAWProxyCount == 0)
    }

    @Test func rawAdjustmentReDevelopsProxy() async throws {
        var decoder = FakeImageDecoder()
        decoder.rawImage = LinearRGBImage(width: 5, height: 5, repeating: 0.75)
        let (service, _, platform, delegate) = makeService(decoder: decoder)
        delegate.previewMaxSize = 512
        service.isRAWSource = true
        service.sourceURL = url
        service.rawAdjustments = RAWAdjustments(exposureEV: 1, temperature: 6000, tint: 0, lensCorrectionEnabled: true)

        service.rawAdjustmentsChanged()
        try await Task.sleep(for: .milliseconds(500))

        #expect(delegate.willAdjustRAWCount == 1)
        #expect(delegate.updateRAWProxyCount == 1)
        #expect(service.sourceImage?.width == 5)
        #expect(service.cachedPreviewMaxSize == 512)
        #expect(platform.purgeCount >= 1)
    }

    @Test func rawAdjustmentFailureReportsToDelegate() async throws {
        var decoder = FakeImageDecoder()
        decoder.shouldFailLoad = true
        let (service, _, _, delegate) = makeService(decoder: decoder)
        service.isRAWSource = true
        service.sourceURL = url

        service.rawAdjustmentsChanged()
        try await Task.sleep(for: .milliseconds(500))

        #expect(delegate.updateRAWProxyCount == 0)
        #expect(delegate.failures.count == 1)
        #expect(delegate.failures.first?.1 == .adjustingRAW)
    }
}

// MARK: - Fakes

private enum FakeCodecError: Error { case boom }

@MainActor
private final class FakeImageDecoder: ImageDecoding {
    var rawDefaultsResult: ImageCodec.RAWDefaults?
    var info = ImageCodec.ImageInfo(width: 1, height: 1)
    var thumbnail = LinearRGBImage(width: 1, height: 1, repeating: 0)
    var rawImage = LinearRGBImage(width: 1, height: 1, repeating: 0)
    var shouldFailInspect = false
    var shouldFailLoad = false

    func rawDefaults(url: URL) -> ImageCodec.RAWDefaults? { rawDefaultsResult }

    func inspect(url: URL) throws -> ImageCodec.ImageInfo {
        if shouldFailInspect { throw FakeCodecError.boom }
        return info
    }

    func loadRAWLinearSRGB(url: URL, maxDimension: Int, adjustments: RAWAdjustments) throws -> LinearRGBImage {
        if shouldFailLoad { throw FakeCodecError.boom }
        return rawImage
    }

    func loadLinearSRGBThumbnail(url: URL, maxDimension: Int) throws -> LinearRGBImage {
        if shouldFailLoad { throw FakeCodecError.boom }
        return thumbnail
    }

    func makeNSImage(_ image: LinearRGBImage, encodeSRGB: Bool) -> NSImage? { nil }
}

@MainActor
private final class FakeImagePicker: ImageFilePicking {
    var url: URL?
    func chooseImageURL() -> URL? { url }
}

@MainActor
private final class FakeImageSourcePlatform: ImageSourcePlatform {
    private(set) var purgeCount = 0
    func purgePreviewStageCache() { purgeCount += 1 }
}

@MainActor
private final class SpyImageServiceDelegate: ImageServiceDelegate {
    var previewMaxSize = 640
    var loadedSourceCount = 0
    var willAdjustRAWCount = 0
    var updateRAWProxyCount = 0
    var failures: [(Error, ImageServiceOperation)] = []

    func imageServicePreviewMaxSize(_ service: ImageService) -> Int { previewMaxSize }

    func imageServiceDidLoadSource(_ service: ImageService) { loadedSourceCount += 1 }

    func imageServiceWillAdjustRAW(_ service: ImageService) { willAdjustRAWCount += 1 }

    func imageServiceDidUpdateRAWProxy(_ service: ImageService) { updateRAWProxyCount += 1 }

    func imageService(_ service: ImageService, didFailWith error: Error, operation: ImageServiceOperation) {
        failures.append((error, operation))
    }
}
