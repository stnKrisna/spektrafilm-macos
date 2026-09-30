import Foundation
import Testing
@testable import SpektrafilmCore

// Tests in this file are direct behavioral ports/adaptations of upstream Python
// spektrafilm tests (profiles, couplers, grain, morph curves, pipeline smoke),
// plus Rust parity invariants where the Swift API exposes the same operation.

private enum ParityFixture {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    static let data = root.appendingPathComponent("Data")

    static func resources() throws -> PipelineResources {
        try PipelineResources.load(dataDirectory: data)
    }

    static func profiles() throws -> [FilmProfile] {
        try ProfileLibrary.loadDirectory(data.appendingPathComponent("profiles"))
    }

    static func profile(_ id: String) throws -> FilmProfile {
        try #require(try profiles().first { $0.id == id })
    }

    static func tile(_ rgb: (Double, Double, Double), size: Int) -> LinearRGBImage {
        var px = [Double]()
        px.reserveCapacity(size * size * 3)
        for _ in 0..<(size * size) { px += [rgb.0, rgb.1, rgb.2] }
        return .init(width: size, height: size, pixels: px)
    }

    static func fastParams() -> RenderParameters {
        var p = RenderParameters()
        p.camera.autoExposure = false
        p.film.halation.active = false
        p.film.grain.active = false
        p.film.dirCouplers.active = false
        p.print.glare.active = false
        p.scanner.lensBlur = 0
        p.scanner.unsharpAmount = 0
        p.io.outputCCTFEncoding = false
        // These ported tests all render with an explicit print profile; disable
        // the direct-scan color positive so defaults never leak in.
        p.io.colorPositive = false
        return p
    }

    static func syntheticMorphProfile(type: String) throws -> FilmProfile {
        let centers = [[-1.2,-0.2,0.8],[-1.1,-0.1,0.9],[-1.0,0.0,1.0]]
        let amps = [[0.25,0.35,0.30],[0.22,0.34,0.33],[0.20,0.32,0.36]]
        let sigmas = [[0.30,0.25,0.35],[0.28,0.24,0.34],[0.26,0.23,0.33]]
        let axis = stride(from: -3.0, through: 2.0, by: 0.05).map { $0 }
        let placeholder = axis.map { _ in [0.0,0.0,0.0] }
        let object: [String: Any] = [
            "metadata": [:],
            "info": ["stock": "synthetic_morph_\(type)", "stage": "printing", "type": type],
            "data": [
                "log_exposure": axis,
                "density_curves": placeholder,
                "density_curves_model": [
                    "model_type": "cdf_sums",
                    "centers": centers,
                    "amplitudes": amps,
                    "sigmas": sigmas
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(FilmProfile.self, from: data)
    }
}

@Test("Python profiles: required data fields and core shapes")
func pythonProfilesRequiredFieldsAndShapes() throws {
    // Adapted from tests/test_profiles.py::test_profile_has_required_fields and
    // ::test_profile_data_shapes_are_consistent.
    for id in ["kodak_portra_400", "fujifilm_c200", "kodak_portra_endura"] {
        let p = try ParityFixture.profile(id)
        #expect(!p.data.logExposure.isEmpty)
        #expect(p.data.densityCurves.count == p.data.logExposure.count)
        #expect(p.data.densityCurves.allSatisfy { $0.count == 3 })
        #expect(!p.data.wavelengths.isEmpty)
        #expect(!p.data.logSensitivity.isEmpty)
        #expect(!p.data.channelDensity.isEmpty)
        #expect(!p.data.baseDensityRows.isEmpty)
    }
}

@Test("Python grain: inactive grain is exact identity")
func pythonGrainInactiveIsIdentity() {
    // Direct behavioral port of tests/test_grain.py::
    // test_apply_grain_returns_input_when_bypassed_or_inactive (inactive branch).
    let input = LinearRGBImage(width: 3, height: 3, repeating: 0.4)
    var p = GrainParameters(); p.active = false
    let out = FilmModels.applyGrain(input, params: p, pixelSizeMicrometers: 4)
    #expect(out == input)
}

@Test("Swift grain: deterministic for a fixed seed")
func swiftGrainFixedSeedIsDeterministic() {
    // Swift currently uses SplitMix64 rather than NumPy MT19937; this checks the
    // deterministic contract without pretending to be Python bit-identical.
    let input = ParityFixture.tile((0.3, 0.6, 0.9), size: 8)
    var p = GrainParameters(); p.active = true; p.sublayersActive = false; p.blur = 0; p.seed = 12345
    let a = FilmModels.applyGrain(input, params: p, pixelSizeMicrometers: 4)
    let b = FilmModels.applyGrain(input, params: p, pixelSizeMicrometers: 4)
    #expect(a == b)
    p.seed = 12346
    let c = FilmModels.applyGrain(input, params: p, pixelSizeMicrometers: 4)
    #expect(c != a)
    #expect(c.allFinite())
}

@Test("Python DIR: zero amount returns developed density unchanged")
func pythonDIRZeroAmountIsIdentity() throws {
    // Equivalent invariant to tests/test_couplers.py zero-inhibition test.
    let profile = try ParityFixture.profile("kodak_portra_400")
    let logRaw = ParityFixture.tile((-1.0, -0.7, -0.4), size: 3)
    let density = FilmModels.develop(logExposure: logRaw, profile: profile, gamma: 1)
    var p = DIRCouplersParameters(); p.active = true; p.amount = 0
    let out = FilmModels.applyDIR(density, logRaw: logRaw, profile: profile, params: p, pixelSizeMicrometers: 10, gamma: 1)
    #expect(out == density)
}

@Test("Python DIR: inactive couplers are exact identity")
func pythonDIRInactiveIsIdentity() throws {
    let profile = try ParityFixture.profile("kodak_portra_400")
    let logRaw = ParityFixture.tile((-1.0, -0.7, -0.4), size: 3)
    let density = FilmModels.develop(logExposure: logRaw, profile: profile, gamma: 1)
    var p = DIRCouplersParameters(); p.active = false; p.amount = 1
    let out = FilmModels.applyDIR(density, logRaw: logRaw, profile: profile, params: p, pixelSizeMicrometers: 10, gamma: 1)
    #expect(out == density)
}

@Test("Python print morph: developer exhaustion preserves logE=0 midgray", arguments: ["positive", "negative"])
func pythonPrintMorphExhaustionPreservesMidgray(profileType: String) throws {
    // Direct port of tests/test_morph_curves.py::
    // test_developer_exhaustion_preserves_midgray_at_loge_zero.
    let profile = try ParityFixture.syntheticMorphProfile(type: profileType)
    let logE = LinearRGBImage(width: 1, height: 1, repeating: 0)
    let baseline = FilmModels.developPrintMorph(logExposure: logE, profile: profile, parameters: .init())
    var params = PrintCurvesMorphParameters(); params.active = true; params.developerExhaustion = 0.35
    let exhausted = FilmModels.developPrintMorph(logExposure: logE, profile: profile, parameters: params)
    for i in 0..<3 { #expect(abs(exhausted.pixels[i] - baseline.pixels[i]) < 1e-9) }
}

@Test("Filming UV/IR filtering preserves reference-illuminant channel energy")
func pythonFilmingUVIRFilterRenormalizesSensitivity() throws {
    // Mirrors the Python filming-stage contract: filtering alters the spectral
    // sensitivity but normalizes each channel under the reference illuminant.
    let profile = try ParityFixture.profile("kodak_portra_400")
    let resources = try ParityFixture.resources()
    let original = profile.data.logSensitivity.map { $0.map { pow(10, $0) } }
    let filtered = SpectralService.filteredCameraSensitivity(
        profile: profile, resources: resources,
        uv: [1.0, 410.0, 8.0], ir: [1.0, 675.0, 15.0]
    )
    #expect(filtered.didFilter)
    let illum = resources.pack.illuminant(profile.info.referenceIlluminant)
    let n = min(illum.count, min(original.count, filtered.sensitivity.count))
    for c in 0..<3 {
        var before = 0.0, after = 0.0
        for i in 0..<n {
            before += original[i][c] * illum[i]
            after += filtered.sensitivity[i][c] * illum[i]
        }
        #expect(abs(after - before) / max(abs(before), 1e-30) < 1e-10)
    }
    #expect(filtered.sensitivity != original)
}

@Test("Rust/Python PCHIP3D invariant: affine volumes interpolate exactly")
func rustPCHIP3DAffineVolumeExactness() {
    // Rust documents its PCHIP3D as a bit-exact port of Python's LUT interpolator.
    // Any affine scalar volume must be reconstructed exactly up to f64 rounding.
    let n = 5
    var values = [Double]()
    for z in 0..<n { for y in 0..<n { for x in 0..<n {
        values.append(1.25 + 0.5 * Double(x) - 0.75 * Double(y) + 1.5 * Double(z))
    }}}
    let p = PreparedPCHIP3D(size: n, channels: 1, values: values)
    for q in [(0.2,0.7,1.1), (1.25,2.5,0.5), (3.1,1.2,2.8)] {
        let expected = 1.25 + 0.5*q.0 - 0.75*q.1 + 1.5*q.2
        #expect(abs(p.sample(x: q.0, y: q.1, z: q.2, channel: 0) - expected) < 1e-10)
    }
}

@Test("Python pipeline smoke: upscale and downscale edge cases")
func pythonPipelineSmokeResizeEdgeCases() throws {
    // Port of the first two cases from tests/test_pipeline_smoke.py.
    let film = try ParityFixture.profile("kodak_portra_400")
    let paper = try ParityFixture.profile("kodak_portra_endura")
    let resources = try ParityFixture.resources()
    for (factor, inputSize, expectedSize) in [(2.0,4,8), (0.5,8,4)] {
        var p = ParityFixture.fastParams(); p.io.upscale = factor
        let result = try SpektrafilmPipeline.render(
            input: ParityFixture.tile((0.30,0.10,0.05), size: inputSize),
            film: film, print: paper, parameters: p, resources: resources
        ).image
        #expect(result.width == expectedSize && result.height == expectedSize)
        #expect(result.allFinite())
    }
}

@Test("Python pipeline smoke: black and extreme inputs stay finite")
func pythonPipelineSmokeExtremeInputs() throws {
    // Port of the black and 10000x-white edge cases from test_pipeline_smoke.py.
    let film = try ParityFixture.profile("kodak_portra_400")
    let paper = try ParityFixture.profile("kodak_portra_endura")
    let resources = try ParityFixture.resources()
    let p = ParityFixture.fastParams()
    for value in [0.0, 10_000.0] {
        let result = try SpektrafilmPipeline.render(
            input: LinearRGBImage(width: 8, height: 8, repeating: value),
            film: film, print: paper, parameters: p, resources: resources
        ).image
        #expect(result.width == 8 && result.height == 8)
        #expect(result.allFinite())
    }
}

@Test("Highlight boost: zero EV is identity and protected values remain unchanged")
func parityHighlightBoostContract() {
    let raw = LinearRGBImage(width: 1, height: 1, pixels: [0.1, 0.5, 10.0])
    #expect(FilmModels.boostHighlights(raw, boostEV: 0, boostRange: 0.3, protectEV: 2) == raw)
    let boosted = FilmModels.boostHighlights(raw, boostEV: 1, boostRange: 0.3, protectEV: 2, midgray: 0.184)
    #expect(abs(boosted.pixels[0] - raw.pixels[0]) < 1e-12)
    #expect(abs(boosted.pixels[1] - raw.pixels[1]) < 1e-12)
    #expect(boosted.pixels[2] > raw.pixels[2])
}
