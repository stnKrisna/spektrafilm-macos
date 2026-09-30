import Foundation
import Testing
@testable import SpektrafilmCore

@Test func linearInterpolation() {
    #expect(abs(Interpolation.linear(x:[0,1], y:[0,10], at:0.25)-2.5) < 1e-12)
}

@Test func pchipPreservesLinearRamp() {
    let x=[0.0,1,2,3], y=[0.0,2,4,6]
    #expect(abs(Interpolation.pchip(x:x,y:y,at:1.5)-3) < 1e-12)
}

@Test func profileSchemaDecodesNullableSpectraAndVectorBaseDensity() throws {
    let json = #"{"metadata":{"version":"x"},"info":{"stock":"demo","name":"Demo","stage":"filming"},"data":{"wavelengths":[400,500],"log_sensitivity":[[-1,null],[-2,-3]],"channel_density":[[null,0.1],[0.2,0.3]],"base_density":[0.01,null],"log_exposure":[-1,0,1],"density_curves":[[0.1,0.1,0.1],[0.5,0.5,0.5],[1.2,1.2,1.2]]}}"#.data(using:.utf8)!
    let p=try JSONDecoder().decode(FilmProfile.self,from:json)
    #expect(p.id == "demo")
    #expect(p.data.logSensitivity[0][1] == 0)
    #expect(p.data.baseDensityRows.count == 2)
    #expect(p.data.baseDensityRows[1][0] == nil)
}

@Test func autoExposureTargetsMidgray() {
    let image=LinearRGBImage(width:4,height:4,repeating:0.184)
    #expect(abs(SpektrafilmPipeline.autoExposureEV(image)) < 1e-10)
}

@Test func pipelineProducesFiniteOutput() throws {
    let json = #"{"metadata":{},"info":{"stock":"demo","stage":"filming"},"data":{"log_exposure":[-4,0,2],"density_curves":[[0.1,0.1,0.1],[0.8,0.8,0.8],[2.0,2.0,2.0]]}}"#.data(using:.utf8)!
    let profile=try JSONDecoder().decode(FilmProfile.self,from:json)
    let image=LinearRGBImage(width:8,height:8,repeating:0.18)
    var params=RenderParameters(); params.film.grain.active=false; params.film.halation.active=false; params.film.dirCouplers.active=false
    let result=try SpektrafilmPipeline.render(input:image,film:profile,print:nil,parameters:params)
    #expect(result.image.width == 8)
    #expect(result.image.allFinite())
}

@Test func pipelineThrowsCancellationErrorMidRender() throws {
    let json = #"{"metadata":{},"info":{"stock":"demo","stage":"filming"},"data":{"log_exposure":[-4,0,2],"density_curves":[[0.1,0.1,0.1],[0.8,0.8,0.8],[2.0,2.0,2.0]]}}"#.data(using:.utf8)!
    let profile=try JSONDecoder().decode(FilmProfile.self,from:json)
    let image=LinearRGBImage(width:16,height:16,repeating:10.0)
    var params=RenderParameters(); params.film.grain.active=false; params.film.halation.active=true; params.film.dirCouplers.active=false
    #expect(throws: CancellationError.self) {
        try SpektrafilmPipeline.render(
            input: image, film: profile, print: nil, parameters: params,
            progress: { _, _ in },
            isCancelled: { true }
        )
    }
}

@Test func boxDownscalePreservesConstantRegions() {
    let value=0.4321
    let image=LinearRGBImage(width:8,height:8,repeating:value)
    let small=Resample.boxAverageDownscale(image, factor:2)
    #expect(small.width == 4)
    #expect(small.height == 4)
    for v in small.pixels { #expect(abs(v-value) < 1e-12) }
}

@Test func resampleRoundTripsDimensions() {
    let image=LinearRGBImage(width:12,height:6,repeating:1)
    let resized=Resample.resize(image, maxDimension:6)
    #expect(resized.width == 6)
    #expect(resized.height == 3)
    let up=Resample.bilinearUpscale(resized, toWidth:12, toHeight:6)
    #expect(up.width == 12 && up.height == 6)
    for v in up.pixels { #expect(v.isFinite) }
}

@Test func halationDownscaleProducesFiniteBlend() throws {
    // Large enough to force the downscale path (width > workDimension=32) but tiny
    // so the debug-build blur stays fast. Exercises downscaleHighlights →
    // gaussianBlur(work) → bilinearUpscale → composite.
    let wide=96, tall=64
    var pixels=[Double](repeating:0,count:wide*tall*3)
    for y in 0..<tall {
        for x in 0..<wide {
            let i=(y*wide+x)*3
            let bright = x > 32 && y > 16 && x < wide - 8 && y < tall - 8
            let v = bright ? 5.0 : 0.05
            pixels[i]=v; pixels[i+1]=v*0.9; pixels[i+2]=v
        }
    }
    let input=LinearRGBImage(width:wide,height:tall,pixels:pixels)
    var params=RenderParameters(); params.film.grain.active=false; params.film.dirCouplers.active=false; params.film.halation.active=true
    let result=try FilmModels.applyHalation(input, params: params.film.halation, pixelSizeMicrometers: 5.892, workDimension: 32)
    #expect(result.width == wide)
    #expect(result.height == tall)
    #expect(result.allFinite())
    // The current Python model renormalizes halation energy, so the bright core can
    // fall slightly while energy moves into the surrounding halo.
    #expect(result[wide/2, tall/2, 0] > 4.0)
    #expect(result[30, tall/2, 0] > input[30, tall/2, 0])
    // The distant dark corner must not gain meaningful bloom and must stay finite.
    #expect(result[0, 0, 0] >= 0.05 - 1e-9)
}

@Test func halationPreservesUniformityAcrossScaleBoundary() throws {
    var params=RenderParameters(); params.film.grain.active=false; params.film.dirCouplers.active=false
    // Full-resolution result on a uniform input (no downscale). Composite weights
    // differ per channel (strength), so expect per-channel constancy only.
    let a=try FilmModels.applyHalation(LinearRGBImage(width:64,height:48,repeating:2.0), params: params.film.halation, pixelSizeMicrometers: 5.892)
    let aMeans=perChannelMeans(a)
    #expect(aMeans.allSatisfy { $0.isFinite })
    for ch in 0..<3 {
        let spread=channelSpread(a, ch)
        #expect(spread < 1e-9)
    }

    // Downscaled path: same inputs, work capped at 32px. Bilinear/box/average of a
    // constant field is exact, so per-channel values must land on the same scalars.
    let b=try FilmModels.applyHalation(LinearRGBImage(width:96,height:64,repeating:2.0), params: params.film.halation, pixelSizeMicrometers: 5.892, workDimension: 32)
    let bMeans=perChannelMeans(b)
    for ch in 0..<3 {
        #expect(abs(bMeans[ch] - aMeans[ch]) < 1e-9)
        #expect(channelSpread(b, ch) < 1e-6)
    }
}

private func perChannelMeans(_ image: LinearRGBImage) -> [Double] {
    var sums=[Double](repeating:0,count:3)
    for i in 0..<(image.width*image.height) {
        for c in 0..<3 { sums[c] += image.pixels[i*3+c] }
    }
    let n=Double(image.width*image.height)
    return sums.map { $0/n }
}

private func channelSpread(_ image: LinearRGBImage, _ channel: Int) -> Double {
    var lo = Double.infinity
    var hi = -Double.infinity
    for i in 0..<(image.width*image.height) {
        let v=image.pixels[i*3+channel]
        lo=min(lo,v); hi=max(hi,v)
    }
    return hi - lo
}

@Test func bundledDataPackAndSFS2Decode() throws {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resources=try PipelineResources.load(dataDirectory:root.appendingPathComponent("Data"))
    #expect(resources.pack.packFormat == 2)
    #expect(resources.pack.wavelengths.count == 81)
    #expect(resources.spectra.width == 192 && resources.spectra.height == 192)
    #expect(resources.spectra.wavelengthCount == 81)
    #expect(resources.spectra.identifier.contains("irradiance_xy_tc"))
}

@Test func tcCoordinatesRoundTrip() {
    let xy=(0.3127,0.3290), tc=ColorScience.xyToTC(xy.0,xy.1), xy2=ColorScience.tcToXY(tc.0,tc.1)
    #expect(abs(xy.0-xy2.0) < 1e-12)
    #expect(abs(xy.1-xy2.1) < 1e-12)
}

@Test func pchip3DLinearCube() {
    let n=3,c=1
    var values=[Double]()
    for z in 0..<n { for y in 0..<n { for x in 0..<n { values.append(Double(x+y+z)) } } }
    let p=PreparedPCHIP3D(size:n,channels:c,values:values)
    #expect(abs(p.sample(x:0.4,y:1.2,z:0.7,channel:0)-2.3) < 1e-10)
}

@Test func upstreamProfilesDecodeAll() throws {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let profiles=try ProfileLibrary.loadDirectory(root.appendingPathComponent("Data/profiles"))
    #expect(profiles.count >= 30)
    #expect(profiles.allSatisfy { !$0.data.logExposure.isEmpty && !$0.data.densityCurves.isEmpty })
}

@Test func realProfileSpectralPipelineProducesFiniteOutput() throws {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data=root.appendingPathComponent("Data")
    let resources=try PipelineResources.load(dataDirectory:data)
    let profiles=try ProfileLibrary.loadDirectory(data.appendingPathComponent("profiles"))
    let film=try #require(profiles.first{$0.id=="kodak_portra_160"})
    let paper=try #require(profiles.first{$0.id=="kodak_portra_endura"})
    let image=LinearRGBImage(width:2,height:2,pixels:[0.18,0.12,0.08, 0.4,0.2,0.1, 0.05,0.1,0.3, 0.8,0.8,0.8])
    var p=RenderParameters(); p.camera.autoExposure=false; p.film.halation.active=false; p.film.grain.active=false; p.film.dirCouplers.active=false; p.scanner.unsharpAmount=0
    let result=try SpektrafilmPipeline.render(input:image,film:film,print:paper,parameters:p,resources:resources)
    #expect(result.image.allFinite())
    #expect(result.image.pixels.contains{$0 > 0})
}

@Test func directNegativeScanColorPositiveInvertsToneScale() throws {
    let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data=root.appendingPathComponent("Data")
    let resources=try PipelineResources.load(dataDirectory:data)
    let profiles=try ProfileLibrary.loadDirectory(data.appendingPathComponent("profiles"))
    let film=try #require(profiles.first{$0.id=="kodak_portra_160"})
    // Two neutral patches: a bright sky-like region and a dim shadow-like region.
    let image=LinearRGBImage(width:2,height:1,pixels:[0.80,0.80,0.80, 0.02,0.02,0.02])
    var p=RenderParameters(); p.camera.autoExposure=false; p.film.halation.active=false; p.film.grain.active=false; p.film.dirCouplers.active=false; p.scanner.unsharpAmount=0

    p.io.colorPositive=false
    let negative=try SpektrafilmPipeline.render(input:image,film:film,print:nil,parameters:p,resources:resources).image
    p.io.colorPositive=true
    let positive=try SpektrafilmPipeline.render(input:image,film:film,print:nil,parameters:p,resources:resources).image
    #expect(negative.allFinite())
    #expect(positive.allFinite())
    for c in 0..<3 {
        // Bright scene -> high negative density -> darker direct scan than the shadows.
        #expect(negative[0,0,c] < negative[1,0,c])
        // Inverted positive rebuilds the tone scale: sky bright, shadows dim.
        #expect(positive[0,0,c] > 0.5)
        #expect(positive[0,0,c] > positive[1,0,c])
        #expect(positive[1,0,c] < 0.5)
    }
}
