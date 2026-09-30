import Foundation
import Testing
@testable import SpektrafilmCore

private struct GoldenFixture: Decodable {
    struct Tolerance: Decodable { let rtol: Double; let atol: Double }
    struct Array3: Decodable {
        let shape: [Int]
        let values: [Double]
    }
    let schemaVersion: Int
    let source: String
    let sourceRevision: String?
    let caseID: String
    let filmProfile: String
    let printProfile: String?
    let imageRecipe: String
    let outputMode: String
    let tolerance: Tolerance
    let expected: Array3
}

private enum GoldenParitySupport {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let data = root.appendingPathComponent("Data")
    static let fixtures = root.appendingPathComponent("Tests/Fixtures/Golden")

    static func allFixtures() throws -> [GoldenFixture] {
        guard FileManager.default.fileExists(atPath: fixtures.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(GoldenFixture.self, from: Data(contentsOf: $0)) }
    }

    static func image(recipe: String) throws -> LinearRGBImage {
        switch recipe {
        case "gray_ramp_16":
            var values = [Double](repeating: 0, count: 16 * 16 * 3)
            for y in 0..<16 { for x in 0..<16 {
                let v = 0.01 + (1.0 - 0.01) * Double(x) / 15.0
                let base = (y * 16 + x) * 3
                values[base] = v; values[base + 1] = v; values[base + 2] = v
            }}
            return .init(width: 16, height: 16, pixels: values)
        case "green_patch_8":
            var values = [Double](); values.reserveCapacity(8 * 8 * 3)
            for _ in 0..<(8 * 8) { values += [0.05, 0.40, 0.05] }
            return .init(width: 8, height: 8, pixels: values)
        default:
            throw NSError(domain: "GoldenParity", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown image recipe: \(recipe)"])
        }
    }

    static func parameters(useGPU: Bool = false) -> RenderParameters {
        // Mirrors upstream tests/conftest.py::make_fast_test_params.
        var p = RenderParameters()
        p.debug.deactivateSpatialEffects = true
        p.debug.deactivateStochasticEffects = true
        p.io.upscale = 1.0
        p.io.crop = false
        // Fixtures capture reference negative-scan behavior, not the app's
        // color-positive default for direct scans.
        p.io.colorPositive = false
        p.camera.autoExposure = false
        p.camera.exposureCompensationEV = 0.0
        p.settings.useMetalExport = useGPU
        return p
    }

    static func loadProfile(_ id: String) throws -> FilmProfile {
        let all = try ProfileLibrary.loadDirectory(data.appendingPathComponent("profiles"))
        return try #require(all.first { $0.id == id }, "Missing profile \(id)")
    }

    static func actual(for fixture: GoldenFixture, useGPU: Bool = false) throws -> LinearRGBImage {
        let resources = try PipelineResources.load(dataDirectory: data)
        let film = try loadProfile(fixture.filmProfile)
        let print = try fixture.printProfile.map(loadProfile)
        let input = try image(recipe: fixture.imageRecipe)
        var tapped: [PipelineTap: LinearRGBImage] = [:]
        let result = try SpektrafilmPipeline.render(
            input: input, film: film, print: print,
            parameters: parameters(useGPU: useGPU), resources: resources,
            tap: { tapped[$0] = $1 }
        )
        if ProcessInfo.processInfo.environment["SPEKTRAFILM_DUMP_TAPS"] == "1" {
            func dumpTaps(name: String, px: [Double]) throws {
                let text = px.map { String($0) }.joined(separator: ",")
                try Data(text.utf8).write(to: URL(fileURLWithPath: "/tmp/spektra_taps_\(name).txt"))
            }
            try dumpTaps(name: "\(fixture.caseID)_pd", px: tapped[.printDensity]?.pixels ?? [])
            try dumpTaps(name: "\(fixture.caseID)_pe", px: tapped[.printExposure]?.pixels ?? [])
            try dumpTaps(name: "\(fixture.caseID)_nd", px: tapped[.negativeDensity]?.pixels ?? [])
        }
        switch fixture.outputMode {
        case "film_raw":
            return try #require(tapped[.filmLogExposure], "filmLogExposure tap was not produced")
        case "negative_density":
            return try #require(tapped[.negativeDensity], "negativeDensity tap was not produced")
        case "print_rgb":
            return result.image
        case "print_exposure":
            return try #require(tapped[.printExposure], "printExposure tap was not produced")
        case "print_density":
            return try #require(tapped[.printDensity], "printDensity tap was not produced")
        case "scanner_linear_rgb":
            return try #require(tapped[.scannerLinearRGB], "scannerLinearRGB tap was not produced")
        default:
            throw NSError(domain: "GoldenParity", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown output mode: \(fixture.outputMode)"])
        }
    }

    static func assertClose(_ actual: LinearRGBImage, _ expected: GoldenFixture.Array3, tolerance: GoldenFixture.Tolerance, caseID: String, backend: String, gate: Bool) {
        #expect(expected.shape.count == 3)
        guard expected.shape.count == 3 else { return }
        #expect(actual.height == expected.shape[0])
        #expect(actual.width == expected.shape[1])
        #expect(expected.shape[2] == 3)
        #expect(actual.pixels.count == expected.values.count)
        guard actual.pixels.count == expected.values.count else { return }

        var maxAbs = 0.0
        var maxRel = 0.0
        var meanAbs = 0.0
        var mse = 0.0
        var mismatches = 0
        var diag = ""
        for i in actual.pixels.indices {
            let a = actual.pixels[i], e = expected.values[i]
            let absErr = abs(a - e)
            let relErr = absErr / max(abs(e), 1e-30)
            maxAbs = max(maxAbs, absErr); maxRel = max(maxRel, relErr); meanAbs += absErr; mse += absErr * absErr
            if absErr > tolerance.atol + tolerance.rtol * abs(e) { mismatches += 1 }
            if i < 48 { diag += "\(i)\(a == 0 ? "" : "a=\(String(format: "%.4f", a))") g=\(String(format: "%.4f", e))  " }
        }
        AppLog.debug("diag", "\(caseID) [\(backend)] row0: \(diag)")
        meanAbs /= Double(max(actual.pixels.count, 1))
        mse /= Double(max(actual.pixels.count, 1))
        AppLog.debug("metrics", "\(backend) \(caseID): maxAbs=\(maxAbs), maxRel=\(maxRel), meanAbs=\(meanAbs), mse=\(mse)")
        if gate {
            #expect(mse <= 0.09, "\(caseID) [\(backend)]: mse=\(mse) exceeds 0.09; \(mismatches) mismatches; maxAbs=\(maxAbs), maxRel=\(maxRel), meanAbs=\(meanAbs), tolerance=(rtol \(tolerance.rtol), atol \(tolerance.atol))")
        }
    }
}

@Test("Python golden regression fixtures", .timeLimit(.minutes(2)))
func pythonGoldenRegressionFixtures() throws {
    let fixtures = try GoldenParitySupport.allFixtures()
    // The repository intentionally contains no copied upstream numerical vectors by
    // default. Run Scripts/import-python-goldens.py against an upstream checkout to
    // populate them. Once present, this becomes a hard numerical parity gate.
    if fixtures.isEmpty {
        if ProcessInfo.processInfo.environment["SPEKTRAFILM_REQUIRE_GOLDENS"] == "1" {
            Issue.record("No Python golden fixtures installed. Run Scripts/import-python-goldens.py against an upstream spektrafilm checkout.")
        }
        return
    }
    let metalAvailable = MetalAccelerator.shared.isAvailable
    for fixture in fixtures {
        #expect(fixture.schemaVersion == 1)
        #expect(fixture.source == "andreavolpato/spektrafilm")
        let cpuActual = try GoldenParitySupport.actual(for: fixture, useGPU: false)
        GoldenParitySupport.assertClose(cpuActual, fixture.expected, tolerance: fixture.tolerance, caseID: fixture.caseID, backend: "cpu", gate: true)
        if metalAvailable {
            let gpuActual = try GoldenParitySupport.actual(for: fixture, useGPU: true)
            GoldenParitySupport.assertClose(gpuActual, fixture.expected, tolerance: fixture.tolerance, caseID: fixture.caseID, backend: "gpu", gate: true)
        } else {
            AppLog.debug("metrics", "gpu \(fixture.caseID): METAL UNAVAILABLE — CPU path only; enable Metal (useMetalExport) to measure the Float32 backend")
        }
    }
}
