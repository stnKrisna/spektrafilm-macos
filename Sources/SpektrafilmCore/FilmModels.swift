import Foundation

public enum FilmModels {
    /// Python reference: normalize density curves, then linear interpolate on log-exposure/gamma.
    public static func develop(logExposure: LinearRGBImage, profile: FilmProfile, gamma: Double, useGPU: Bool = false) -> LinearRGBImage {
        let curves = normalizedCurves(profile.data.densityCurves)
        if useGPU, let accelerated = MetalAccelerator.shared.develop(logExposure, axis: profile.data.logExposure, curves: curves, gamma: gamma, cacheKey: profile.id) {
            return accelerated
        }
        return develop(
            logExposure: logExposure,
            logExposureAxis: profile.data.logExposure,
            densityCurves: curves,
            gamma: gamma
        )
    }

    public static func normalizedCurves(_ curves: [[Double]]) -> [[Double]] {
        guard !curves.isEmpty else { return curves }
        let channels = curves.map(\.count).min() ?? 0
        var mins = [Double](repeating: .infinity, count: channels)
        for row in curves {
            for c in 0..<channels where row[c].isFinite { mins[c] = min(mins[c], row[c]) }
        }
        return curves.map { row in
            (0..<channels).map { c in row[c] - (mins[c].isFinite ? mins[c] : 0) }
        }
    }

    public static func develop(
        logExposure: LinearRGBImage,
        logExposureAxis: [Double],
        densityCurves: [[Double]],
        gamma: Double
    ) -> LinearRGBImage {
        guard logExposureAxis.count >= 2, densityCurves.count == logExposureAxis.count else { return logExposure }
        let channels = densityCurves.map(\.count).min() ?? 0
        guard channels > 0 else { return logExposure }
        let g = max(gamma, 1e-12)
        let axes = (0..<3).map { _ in logExposureAxis.map { $0 / g } }
        let curves = (0..<3).map { c in densityCurves.map { $0[min(c, channels - 1)] } }
        var out = LinearRGBImage(width: logExposure.width, height: logExposure.height)
        for y in 0..<out.height { for x in 0..<out.width { for c in 0..<3 {
            out[x, y, c] = linearInterp(logExposure[x, y, c], x: axes[c], y: curves[c])
        }}}
        return out
    }

    /// Current Python print chemistry first samples/morphs the fitted multi-layer
    /// model on the profile log-exposure axis, then linearly interpolates that table.
    public static func developPrintMorph(
        logExposure: LinearRGBImage,
        profile: FilmProfile,
        parameters: PrintCurvesMorphParameters
    ) -> LinearRGBImage {
        guard let model = profile.data.densityCurvesModel,
              model.centers.count >= 3, model.amplitudes.count >= 3, model.sigmas.count >= 3,
              !profile.data.logExposure.isEmpty else {
            return develop(logExposure: logExposure, profile: profile, gamma: 1)
        }
        let positive = profile.info.type == "positive"
        var channelParams: [([Double],[Double],[Double],[Double])] = []
        for c in 0..<3 {
            var centers=model.centers[c], amplitudes=model.amplitudes[c], sigmas=model.sigmas[c]
            let n=min(centers.count,min(amplitudes.count,sigmas.count)); centers=Array(centers.prefix(n)); amplitudes=Array(amplitudes.prefix(n)); sigmas=Array(sigmas.prefix(n))
            guard n > 0 else { channelParams.append(([],[],[],[])); continue }
            var mixes=Array(repeating:0.0,count:n)
            if parameters.active {
                let order=(0..<n).sorted{centers[$0]<centers[$1]}; let fast=order[0], mid=order[n/2], slow=order[n-1]
                let channelGamma=[parameters.gammaFactorRed,parameters.gammaFactorGreen,parameters.gammaFactorBlue][c]
                let gf=max(parameters.gammaFactor*channelGamma*parameters.gammaFactorFast,1e-12)
                let gs=max(parameters.gammaFactor*channelGamma*parameters.gammaFactorSlow,1e-12)
                for (idx,g) in [(fast,gf),(mid,gs),(slow,gs)] { sigmas[idx]=max(sigmas[idx]/g,0.05); centers[idx] /= g }
                let mix=min(max(parameters.developerExhaustion,0),1); mixes=Array(repeating:mix,count:n)
                if mix > 0 {
                    let target=evaluateDensity(0,centers:model.centers[c],amplitudes:model.amplitudes[c],sigmas:model.sigmas[c],positive:positive,mixes:Array(repeating:0,count:model.centers[c].count))
                    func residual(_ offset:Double)->Double { evaluateDensity(0,centers:centers.map{$0+offset},amplitudes:amplitudes,sigmas:sigmas,positive:positive,mixes:mixes)-target }
                    var lo = -0.25, hi = 0.25, rlo = residual(-0.25), rhi = residual(0.25)
                    for _ in 0..<12 where rlo*rhi >= 0 { lo*=2; hi*=2; rlo=residual(lo); rhi=residual(hi) }
                    if rlo*rhi < 0 {
                        for _ in 0..<60 { let m=(lo+hi)/2, rm=residual(m); if rlo*rm <= 0 { hi=m; rhi=rm } else { lo=m; rlo=rm } }
                        let off=(lo+hi)/2; centers=centers.map{$0+off}
                    }
                }
            }
            channelParams.append((centers,amplitudes,sigmas,mixes))
        }
        let curves=profile.data.logExposure.map { e in
            (0..<3).map { c in let q=channelParams[c]; return evaluateDensity(e,centers:q.0,amplitudes:q.1,sigmas:q.2,positive:positive,mixes:q.3) }
        }
        return develop(logExposure:logExposure, logExposureAxis:profile.data.logExposure, densityCurves:curves, gamma:1)
    }

    private static func evaluateDensity(_ x:Double, centers:[Double], amplitudes:[Double], sigmas:[Double], positive:Bool, mixes:[Double])->Double {
        var total=0.0
        let gumbelLocation = -log(log(2.0))
        let gumbelWidth = 0.5 * log(2.0) * sqrt(2.0 * Double.pi)
        for i in 0..<min(centers.count,min(amplitudes.count,sigmas.count)) {
            let z=(x-centers[i])/max(sigmas[i],1e-12), signed=positive ? -z : z
            let normal=0.5*(1+erf(signed/sqrt(2.0)))
            let gumbel=exp(-exp(-(signed/gumbelWidth + gumbelLocation)))
            let mix=i<mixes.count ? mixes[i] : 0
            total += amplitudes[i]*((1-mix)*normal+mix*gumbel)
        }
        return total
    }

    /// Python apply_density_correction_dir_couplers semantics.
    public static func applyDIR(
        _ density: LinearRGBImage,
        logRaw: LinearRGBImage,
        profile: FilmProfile,
        params: DIRCouplersParameters,
        pixelSizeMicrometers: Double,
        gamma: Double,
        useGPU: Bool = false
    ) -> LinearRGBImage {
        guard params.active && params.amount != 0 else { return density }
        let curves = normalizedCurves(profile.data.densityCurves)
        let logExposure = profile.data.logExposure
        guard curves.count == logExposure.count, !curves.isEmpty else { return density }
        let positive = profile.info.type == "positive"
        let matrix = couplerMatrix(params)
        let preCurves = curvesBeforeDIR(curves: curves, logExposure: logExposure, matrix: matrix, positive: positive)
        var maxDensity = [0.0, 0.0, 0.0]
        for c in 0..<3 { maxDensity[c] = curves.compactMap { $0.indices.contains(c) ? $0[c] : nil }.max() ?? 0 }

        var inhibitor: LinearRGBImage
        if useGPU, let accelerated = MetalAccelerator.shared.dirInhibitor(density, matrix: matrix, maxDensity: maxDensity, positive: positive) {
            inhibitor = accelerated
        } else {
            inhibitor = LinearRGBImage(width: density.width, height: density.height)
            for y in 0..<density.height { for x in 0..<density.width {
                let silver = (0..<3).map { c in positive ? maxDensity[c] - density[x, y, c] : density[x, y, c] }
                for receiver in 0..<3 {
                    inhibitor[x, y, receiver] = (0..<3).reduce(0.0) { sum, donor in
                        sum + silver[donor] * matrix[donor][receiver]
                    }
                }
            }}
        }

        let pixel = max(pixelSizeMicrometers, 1e-12)
        let sigma = params.diffusionSizeMicrometers / pixel
        if sigma > 0 {
            let core = Convolution.gaussianBlur(inhibitor, sigma: sigma, useGPU: useGPU)
            let tailDecay = params.diffusionTailMicrometers / pixel
            let tail = Convolution.exponentialBlur(inhibitor, decay: [tailDecay, tailDecay, tailDecay], useGPU: useGPU)
            let w = params.diffusionTailWeight
            for i in inhibitor.pixels.indices { inhibitor.pixels[i] = (1 - w) * core.pixels[i] + w * tail.pixels[i] }
        }

        if useGPU, let accelerated = MetalAccelerator.shared.dirRedevelop(logRaw, inhibitor: inhibitor, axis: logExposure, curves: preCurves, gamma: gamma, cacheKey: "\(profile.id):\(params.amount)") {
            return accelerated
        }
        var corrected = logRaw
        for i in corrected.pixels.indices { corrected.pixels[i] -= inhibitor.pixels[i] }
        return develop(logExposure: corrected, logExposureAxis: logExposure, densityCurves: preCurves, gamma: gamma)
    }

    private static func couplerMatrix(_ p: DIRCouplersParameters) -> [[Double]] {
        let a = p.amount
        return [
            [p.gammaSameLayerRGB[0] * p.inhibitionSameLayer * a, p.gammaInterLayerRToGB[0] * p.inhibitionInterLayer * a, p.gammaInterLayerRToGB[1] * p.inhibitionInterLayer * a],
            [p.gammaInterLayerGToRB[0] * p.inhibitionInterLayer * a, p.gammaSameLayerRGB[1] * p.inhibitionSameLayer * a, p.gammaInterLayerGToRB[1] * p.inhibitionInterLayer * a],
            [p.gammaInterLayerBToRG[0] * p.inhibitionInterLayer * a, p.gammaInterLayerBToRG[1] * p.inhibitionInterLayer * a, p.gammaSameLayerRGB[2] * p.inhibitionSameLayer * a],
        ]
    }

    private static func curvesBeforeDIR(
        curves: [[Double]], logExposure: [Double], matrix: [[Double]], positive: Bool
    ) -> [[Double]] {
        let n = min(curves.count, logExposure.count)
        guard n > 1 else { return curves }
        var maxDensity = [0.0, 0.0, 0.0]
        for c in 0..<3 { maxDensity[c] = curves.map { $0[c] }.max() ?? 0 }
        var shiftedAxis = Array(repeating: Array(repeating: 0.0, count: 3), count: n)
        for j in 0..<n { for receiver in 0..<3 {
            var amount = 0.0
            for donor in 0..<3 {
                let d = positive ? maxDensity[donor] - curves[j][donor] : curves[j][donor]
                amount += d * matrix[donor][receiver]
            }
            shiftedAxis[j][receiver] = logExposure[j] - amount
        }}
        var out = Array(repeating: Array(repeating: 0.0, count: 3), count: n)
        for j in 0..<n { for c in 0..<3 {
            let xa = (0..<n).map { shiftedAxis[$0][c] }
            let ya = (0..<n).map { positive ? -curves[$0][c] : curves[$0][c] }
            let v = linearInterp(logExposure[j], x: xa, y: ya)
            out[j][c] = positive ? -v : v
        }}
        return out
    }

    /// Poisson→Binomial particle model. When profile layer curves are available and
    /// sublayers are enabled this follows Python's `apply_grain_to_density_layers` topology.
    public static func applyGrain(
        _ density: LinearRGBImage,
        params: GrainParameters,
        profile: FilmProfile? = nil,
        pixelSizeMicrometers: Double = 10,
        useGPU: Bool = false
    ) -> LinearRGBImage {
        guard params.active else { return density }
        if params.sublayersActive, let profile, profile.data.densityCurvesLayers.count == profile.data.densityCurves.count,
           !profile.data.densityCurvesLayers.isEmpty, profile.data.densityCurvesLayers[0].count >= 3 {
            if useGPU, let accelerated = acceleratedLayerGrain(density, params: params, profile: profile, pixelSizeMicrometers: pixelSizeMicrometers) {
                AppLog.debug("metal", "grain: GPU sublayer approximation")
                var out = accelerated
                if params.blur > 0 { out = Convolution.gaussianBlur(out, sigma: params.blur, useGPU: true) }
                return out
            }
            return applyLayerGrain(density, params:params, profile:profile, pixelSizeMicrometers:pixelSizeMicrometers, useGPU:useGPU)
        }
        var rng = SplitMix64(seed: params.seed)
        var out = density
        let curves = profile.map { normalizedCurves($0.data.densityCurves) } ?? []
        let dmax = (0..<3).map { c in
            (curves.compactMap { $0.indices.contains(c) ? $0[c] : nil }.max() ?? 2.2) + params.densityMin[c]
        }
        if useGPU, let accelerated = MetalAccelerator.shared.grainSimple(density, params: params, densityMax: dmax, pixelSizeMicrometers: pixelSizeMicrometers) {
            AppLog.debug("metal", "grain: GPU simple approximation")
            out = accelerated
            if params.blur > 0.4 { out = Convolution.gaussianBlur(out, sigma: params.blur, useGPU: true) }
            return out
        }
        let pixelArea = pixelSizeMicrometers * pixelSizeMicrometers
        let sublayers=max(params.numberOfSublayers,1)
        for y in 0..<density.height { for x in 0..<density.width { for c in 0..<3 {
            var accumulated=0.0
            for _ in 0..<sublayers {
                let maxD = max(dmax[c], 1e-9)
                let d = max(density[x, y, c] + params.densityMin[c], 0)
                let npp = max(pixelArea / (params.particleAreaMicrometers2 * params.particleScale[c]) / Double(sublayers), 1e-6)
                accumulated += particleSample(density:d,densityMax:maxD,npp:npp,uniformity:params.uniformity[c],rng:&rng)
            }
            out[x,y,c] = accumulated/Double(sublayers) - params.densityMin[c]
        }}}
        if params.blur > 0.4 { out = Convolution.gaussianBlur(out, sigma: params.blur, useGPU: useGPU) }
        return out
    }

    private static func acceleratedLayerGrain(_ density: LinearRGBImage, params: GrainParameters, profile: FilmProfile, pixelSizeMicrometers: Double) -> LinearRGBImage? {
        let totalCurves = normalizedCurves(profile.data.densityCurves)
        let layers = profile.data.densityCurvesLayers
        let n = min(totalCurves.count, layers.count)
        guard n > 1 else { return nil }
        let positive = profile.info.type == "positive"
        var maxLayers = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for i in 0..<n { for sl in 0..<3 { for c in 0..<3 where sl < layers[i].count && c < layers[i][sl].count {
            maxLayers[sl][c] = max(maxLayers[sl][c], layers[i][sl][c])
        }}}
        let totals = (0..<3).map { c in max((0..<3).reduce(0.0) { $0 + maxLayers[$1][c] }, 1e-30) }
        let fractions = (0..<3).map { sl in (0..<3).map { c in maxLayers[sl][c] / totals[c] } }
        let minLayers = (0..<3).map { sl in (0..<3).map { c in fractions[sl][c] * params.densityMin[c] } }
        var xAxes = [Float](); xAxes.reserveCapacity(9*n)
        var yAxes = [Float](); yAxes.reserveCapacity(9*n)
        var densityMax = [Float](); densityMax.reserveCapacity(9)
        var densityMin = [Float](); densityMin.reserveCapacity(9)
        var frac = [Float](); frac.reserveCapacity(9)
        let emptyCurve = [0.0, 0.0, 0.0]
        for sl in 0..<3 { for c in 0..<3 {
            for i in 0..<n {
                let curve = totalCurves[i]
                let x = curve.isEmpty ? 0 : curve[min(c, curve.count - 1)]
                xAxes.append(Float(positive ? -x : x))
                // Sublayer channel arrays may be shorter than 3 (monochrome
                // stocks like kodak_trix store a single gray channel); clamp the
                // index and fall back to channel 0, mirroring develop().
                let sublayers = layers[i]
                let layerCurve: [Double] = sl < sublayers.count && !sublayers[sl].isEmpty ? sublayers[sl] : emptyCurve
                let y = layerCurve[min(c, layerCurve.count - 1)]
                yAxes.append(Float(positive ? -y : y))
            }
            densityMax.append(Float(max(maxLayers[sl][c] + minLayers[sl][c], 1e-9)))
            densityMin.append(Float(minLayers[sl][c]))
            frac.append(Float(fractions[sl][c]))
        }}
        return MetalAccelerator.shared.grainLayers(density, params: params, xAxes: xAxes, yAxes: yAxes, densityMax: densityMax, densityMin: densityMin, fractions: frac, curveCount: n, positive: positive, pixelSizeMicrometers: pixelSizeMicrometers)
    }

    private static func applyLayerGrain(_ density:LinearRGBImage,params:GrainParameters,profile:FilmProfile,pixelSizeMicrometers:Double,useGPU:Bool)->LinearRGBImage {
        let totalCurves=normalizedCurves(profile.data.densityCurves), layers=profile.data.densityCurvesLayers
        let n=min(totalCurves.count,layers.count), positive=profile.info.type=="positive"
        guard n>1 else { return density }
        var maxLayers=Array(repeating:Array(repeating:0.0,count:3),count:3)
        for i in 0..<n { for sl in 0..<3 { for c in 0..<3 where sl<layers[i].count && c<layers[i][sl].count { maxLayers[sl][c]=max(maxLayers[sl][c],layers[i][sl][c]) } } }
        let totals=(0..<3).map { c in max((0..<3).reduce(0.0){$0+maxLayers[$1][c]},1e-30) }
        let fractions=(0..<3).map { sl in (0..<3).map { c in maxLayers[sl][c]/totals[c] } }
        let minLayers=(0..<3).map { sl in (0..<3).map { c in fractions[sl][c]*params.densityMin[c] } }
        let pixelArea=pixelSizeMicrometers*pixelSizeMicrometers
        var layerImages=(0..<9).map { _ in LinearRGBImage(width:density.width,height:density.height) }
        for sl in 0..<3 { for c in 0..<3 {
            var rng=SplitMix64(seed:params.seed + UInt64(c + sl*10))
            let particleArea=max(params.particleAreaMicrometers2*params.particleScale[c]*params.particleScaleLayers[min(sl,params.particleScaleLayers.count-1)],1e-12)
            let npp=max(pixelArea*fractions[sl][c]/particleArea,1e-9)
            let densityMax=max(maxLayers[sl][c]+minLayers[sl][c],1e-9)
            let xAxis=(0..<n).map { positive ? -totalCurves[$0][c] : totalCurves[$0][c] }
            let yAxis=(0..<n).map { positive ? -layers[$0][sl][c] : layers[$0][sl][c] }
            let li=sl*3+c
            for y in 0..<density.height { for x in 0..<density.width {
                let q=positive ? -density[x,y,c] : density[x,y,c]
                let layerD=(positive ? -linearInterp(q,x:xAxis,y:yAxis) : linearInterp(q,x:xAxis,y:yAxis)) + minLayers[sl][c]
                layerImages[li][x,y,c]=particleSample(density:max(layerD,0),densityMax:densityMax,npp:npp,uniformity:params.uniformity[c],rng:&rng)
            }}
            let odParticle=densityMax/npp
            let particleBlur=params.blurDyeCloudsMicrometers*sqrt(max(odParticle,0))
            if particleBlur>0 { layerImages[li]=Convolution.gaussianBlur(layerImages[li],sigma:particleBlur,useGPU:useGPU) }
        }}
        var out=LinearRGBImage(width:density.width,height:density.height)
        for y in 0..<out.height { for x in 0..<out.width { for c in 0..<3 {
            out[x,y,c]=(0..<3).reduce(0.0){$0+layerImages[$1*3+c][x,y,c]} - params.densityMin[c]
        }}}
        // Python micro-structure: lognormal multiplicative clumping, spatially correlated when requested.
        let microSigma=(params.microStructure.count>1 ? params.microStructure[1] : 30)*0.001/max(pixelSizeMicrometers,1e-12)
        if microSigma>0.05 {
            let sigma2=log(1+microSigma*microSigma), sigma=sqrt(sigma2), mu = -sigma2/2
            var rng=SplitMix64(seed:params.seed ^ 0x9e3779b97f4a7c15), clump=LinearRGBImage(width:out.width,height:out.height)
            for i in clump.pixels.indices { clump.pixels[i]=exp(mu+sigma*rng.normal()) }
            let blur=(params.microStructure.first ?? 0.2)/max(pixelSizeMicrometers,1e-12)
            if blur>0.4 { clump=Convolution.gaussianBlur(clump,sigma:blur,useGPU:useGPU) }
            for i in out.pixels.indices { out.pixels[i]*=clump.pixels[i] }
        }
        if params.blur>0 { out=Convolution.gaussianBlur(out,sigma:params.blur,useGPU:useGPU) }
        return out
    }


#if canImport(Metal)
    /// Preview-only resident development. The image never leaves its Float32 Metal buffer.
    public static func developResident(_ logExposure: MetalAccelerator.ResidentImage, profile: FilmProfile, gamma: Double) -> MetalAccelerator.ResidentImage? {
        MetalAccelerator.shared.developResident(logExposure, axis: profile.data.logExposure, curves: normalizedCurves(profile.data.densityCurves), gamma: gamma, cacheKey: profile.id)
    }

    public static func applyDIRResident(
        _ density: MetalAccelerator.ResidentImage,
        logRaw: MetalAccelerator.ResidentImage,
        profile: FilmProfile,
        params: DIRCouplersParameters,
        pixelSizeMicrometers: Double,
        gamma: Double
    ) -> MetalAccelerator.ResidentImage? {
        guard params.active && params.amount != 0 else { return density }
        let curves = normalizedCurves(profile.data.densityCurves), logExposure = profile.data.logExposure
        guard curves.count == logExposure.count, !curves.isEmpty else { return density }
        let positive = profile.info.type == "positive", matrix = couplerMatrix(params), preCurves = curvesBeforeDIR(curves: curves, logExposure: logExposure, matrix: matrix, positive: positive)
        var maxDensity=[0.0,0.0,0.0];for c in 0..<3{maxDensity[c]=curves.compactMap{$0.indices.contains(c) ? $0[c]:nil}.max() ?? 0}
        guard var inhibitor=MetalAccelerator.shared.dirInhibitorResident(density,matrix:matrix,maxDensity:maxDensity,positive:positive) else{return nil}
        let sigma=params.diffusionSizeMicrometers/max(pixelSizeMicrometers,1e-12)
        if sigma>0 {
            guard let core=MetalAccelerator.shared.gaussianBlurResident(inhibitor,sigmas:[sigma,sigma,sigma]),
                  let tail=MetalAccelerator.shared.exponentialBlurResident(inhibitor,decay:Array(repeating:params.diffusionTailMicrometers/max(pixelSizeMicrometers,1e-12),count:3)),
                  let mixed=MetalAccelerator.shared.blendResident(core,tail,weightB:params.diffusionTailWeight) else{return nil}
            inhibitor=mixed
        }
        return MetalAccelerator.shared.dirRedevelopResident(logRaw,inhibitor:inhibitor,axis:logExposure,curves:preCurves,gamma:gamma,cacheKey:"\(profile.id):resident")
    }

    public static func applyHalationResident(_ raw: MetalAccelerator.ResidentImage, params: HalationParameters, pixelSizeMicrometers: Double) -> MetalAccelerator.ResidentImage? {
        guard params.active else { return raw }
        let pixel = max(pixelSizeMicrometers, 1e-12)
        var image = raw
        let coreSigma = params.scatterCoreMicrometers.map { $0 * params.scatterSpatialScale / pixel }
        let tailDecay = params.scatterTailMicrometers.map { $0 * params.scatterSpatialScale / pixel }
        if params.scatterAmount > 0 && (coreSigma.contains { $0 > 0 } || tailDecay.contains { $0 > 0 }) {
            guard let core = MetalAccelerator.shared.gaussianBlurResident(image, sigmas: coreSigma),
                  let tail = MetalAccelerator.shared.exponentialBlurResident(image, decay: tailDecay),
                  let scattered = MetalAccelerator.shared.combineChannelsResident(core, tail,
                    weightA: SIMD3<Double>(1 - (params.scatterTailWeight.indices.contains(0) ? params.scatterTailWeight[0] : 0), 1 - (params.scatterTailWeight.indices.contains(1) ? params.scatterTailWeight[1] : 0), 1 - (params.scatterTailWeight.indices.contains(2) ? params.scatterTailWeight[2] : 0)),
                    weightB: SIMD3<Double>(params.scatterTailWeight.indices.contains(0) ? params.scatterTailWeight[0] : 0, params.scatterTailWeight.indices.contains(1) ? params.scatterTailWeight[1] : 0, params.scatterTailWeight.indices.contains(2) ? params.scatterTailWeight[2] : 0)),
                  let mixed = MetalAccelerator.shared.linearCombineResident(image, scattered, weightA: 1 - params.scatterAmount, weightB: params.scatterAmount) else { return nil }
            image = mixed
        }
        let n = max(params.bounceCount, 0)
        if n > 0 {
            let decay = (0..<n).map { pow(params.bounceDecay, Double($0)) }
            let sum = max(decay.reduce(0,+), 1e-30)
            var accumulated: MetalAccelerator.ResidentImage?
            for k in 1...n {
                let sigmas = params.firstSigmaMicrometers.map { $0 * params.halationSpatialScale / pixel * sqrt(Double(k)) }
                guard let blurred = MetalAccelerator.shared.gaussianBlurResident(image, sigmas: sigmas) else { return nil }
                let w = decay[k - 1] / sum
                if let a = accumulated { accumulated = MetalAccelerator.shared.linearCombineResident(a, blurred, weightA: 1, weightB: w) }
                else { accumulated = MetalAccelerator.shared.linearCombineResident(blurred, blurred, weightA: w, weightB: 0) }
            }
            guard let accumulated else { return nil }
            let amounts = (0..<3).map { c in (params.strength.indices.contains(c) ? params.strength[c] : 0) * params.halationAmount }
            let wa = SIMD3<Double>(
                params.renormalize ? 1 / (1 + amounts[0]) : 1,
                params.renormalize ? 1 / (1 + amounts[1]) : 1,
                params.renormalize ? 1 / (1 + amounts[2]) : 1)
            let wb = SIMD3<Double>(
                params.renormalize ? amounts[0] / (1 + amounts[0]) : amounts[0],
                params.renormalize ? amounts[1] / (1 + amounts[1]) : amounts[1],
                params.renormalize ? amounts[2] / (1 + amounts[2]) : amounts[2])
            guard let combined = MetalAccelerator.shared.combineChannelsResident(image, accumulated, weightA: wa, weightB: wb) else { return nil }
            image = combined
        }
        return image
    }

    public static func applyGrainResident(_ density: MetalAccelerator.ResidentImage, params: GrainParameters, profile: FilmProfile, pixelSizeMicrometers: Double, sourceOrigin: SIMD2<UInt32> = .zero, sourceWidth: UInt32 = 0, renderScale: Double = 1) -> MetalAccelerator.ResidentImage? {
        guard params.active else { return density }
        var out: MetalAccelerator.ResidentImage?
        if params.sublayersActive, profile.data.densityCurvesLayers.count == profile.data.densityCurves.count, !profile.data.densityCurvesLayers.isEmpty, profile.data.densityCurvesLayers[0].count >= 3 {
            let totalCurves=normalizedCurves(profile.data.densityCurves),layers=profile.data.densityCurvesLayers,n=min(totalCurves.count,layers.count)
            guard n>1 else{return density};let positive=profile.info.type=="positive"
            var maxLayers=Array(repeating:Array(repeating:0.0,count:3),count:3)
            for i in 0..<n{for sl in 0..<3{for c in 0..<3 where sl<layers[i].count && c<layers[i][sl].count{maxLayers[sl][c]=max(maxLayers[sl][c],layers[i][sl][c])}}}
            let totals=(0..<3).map{c in max((0..<3).reduce(0.0){$0+maxLayers[$1][c]},1e-30)}, fractions=(0..<3).map{sl in (0..<3).map{c in maxLayers[sl][c]/totals[c]}}, minLayers=(0..<3).map{sl in (0..<3).map{c in fractions[sl][c]*params.densityMin[c]}}
            var xAxes=[Float](),yAxes=[Float](),densityMax=[Float](),densityMin=[Float](),frac=[Float]();xAxes.reserveCapacity(9*n);yAxes.reserveCapacity(9*n)
            let emptyCurve=[0.0,0.0,0.0]
            for sl in 0..<3{for c in 0..<3{for i in 0..<n{let curve=totalCurves[i],x=curve.isEmpty ? 0:curve[min(c,curve.count-1)];xAxes.append(Float(positive ? -x:x));let subs=layers[i],lc:[Double]=sl<subs.count && !subs[sl].isEmpty ? subs[sl]:emptyCurve;let y=lc[min(c,lc.count-1)];yAxes.append(Float(positive ? -y:y))};densityMax.append(Float(max(maxLayers[sl][c]+minLayers[sl][c],1e-9)));densityMin.append(Float(minLayers[sl][c]));frac.append(Float(fractions[sl][c]))}}
            out=MetalAccelerator.shared.grainLayersResident(density,params:params,xAxes:xAxes,yAxes:yAxes,densityMax:densityMax,densityMin:densityMin,fractions:frac,curveCount:n,positive:positive,pixelSizeMicrometers:pixelSizeMicrometers,sourceOrigin:sourceOrigin,sourceWidth:sourceWidth,renderScale:renderScale)
        } else {
            let curves=normalizedCurves(profile.data.densityCurves),dmax=(0..<3).map{c in (curves.compactMap{$0.indices.contains(c) ? $0[c]:nil}.max() ?? 2.2)+params.densityMin[c]}
            out=MetalAccelerator.shared.grainSimpleResident(density,params:params,densityMax:dmax,pixelSizeMicrometers:pixelSizeMicrometers,sourceOrigin:sourceOrigin,sourceWidth:sourceWidth,renderScale:renderScale)
        }
        guard var result=out else{return nil}
        if params.blur>0.4,let blurred=MetalAccelerator.shared.gaussianBlurResident(result,sigmas:[params.blur,params.blur,params.blur]){result=blurred}
        return result
    }
#endif

    private static func particleSample(density:Double,densityMax:Double,npp:Double,uniformity:Double,rng:inout SplitMix64)->Double {
        let probability=min(max(density/max(densityMax,1e-30),1e-6),1-1e-6)
        let saturation=1-probability*uniformity*(1-1e-6)
        let seeds=poisson(npp/max(saturation,1e-12),&rng)
        let developed=binomial(seeds,probability,&rng)
        return Double(developed)*(densityMax/max(npp,1e-30))*saturation
    }


    public static func boostHighlights(_ raw: LinearRGBImage, boostEV: Double, boostRange: Double, protectEV: Double, midgray: Double = 0.184) -> LinearRGBImage {
        guard boostEV > 0 else { return raw }
        let maxRaw = raw.pixels.max() ?? 0
        guard maxRaw > 0 else { return raw }
        let rawX0 = min(max(midgray * pow(2, protectEV), 0), maxRaw)
        guard rawX0 < maxRaw else { return raw }
        let a = pow(28.0, 1.0 - min(max(boostRange, 0), 1))
        let x0 = rawX0 / maxRaw
        let denom = exp(a * (1 - x0)) - a * (1 - x0) - 1
        guard denom > 0 else { return raw }
        let k = (pow(2, boostEV) - 1) / denom
        let inv = 1 / maxRaw, scale = k * maxRaw
        var out = raw
        for i in out.pixels.indices {
            let x = raw.pixels[i]
            if x > rawX0 {
                let dx = (x - rawX0) * inv
                out.pixels[i] = x + scale * (exp(a * dx) - a * dx - 1)
            }
        }
        return out
    }

    /// Python apply_halation_um: scatter (Gaussian core + exponential tail), then normalized multi-bounce halation.
    public static func applyHalation(
        _ raw: LinearRGBImage,
        params: HalationParameters,
        pixelSizeMicrometers: Double,
        workDimension: Int = 0,
        useGPU: Bool = false,
        halationProgress: (Double) -> Void = { _ in },
        cancelled: () -> Bool = { false }
    ) throws -> LinearRGBImage {
        guard params.active else { return raw }
        if cancelled() { throw CancellationError() }
        var image = raw
        let pixel = max(pixelSizeMicrometers, 1e-12)

        let coreSigma = params.scatterCoreMicrometers.map { $0 * params.scatterSpatialScale / pixel }
        let tailDecay = params.scatterTailMicrometers.map { $0 * params.scatterSpatialScale / pixel }
        if params.scatterAmount > 0 && (coreSigma.contains { $0 > 0 } || tailDecay.contains { $0 > 0 }) {
            let core = Convolution.gaussianBlur(image, sigmas: coreSigma, useGPU: useGPU)
            let tail = Convolution.exponentialBlur(image, decay: tailDecay, useGPU: useGPU)
            let original = image
            for y in 0..<image.height { for x in 0..<image.width { for c in 0..<3 {
                let scattered = (1 - params.scatterTailWeight[c]) * core[x, y, c] + params.scatterTailWeight[c] * tail[x, y, c]
                image[x, y, c] = (1 - params.scatterAmount) * original[x, y, c] + params.scatterAmount * scattered
            }}}
        }

        let n = max(params.bounceCount, 0)
        if n > 0 {
            let decay = (0..<n).map { pow(params.bounceDecay, Double($0)) }
            let decaySum = max(decay.reduce(0, +), 1e-30)
            var accumulated = LinearRGBImage(width: image.width, height: image.height)
            for k in 1...n {
                if cancelled() { throw CancellationError() }
                let sigmas = params.firstSigmaMicrometers.map { $0 * params.halationSpatialScale / pixel * sqrt(Double(k)) }
                let blurred = Convolution.gaussianBlur(image, sigmas: sigmas, useGPU: useGPU)
                let weight = decay[k - 1] / decaySum
                for i in accumulated.pixels.indices { accumulated.pixels[i] += weight * blurred.pixels[i] }
                halationProgress(Double(k) / Double(n))
            }
            for y in 0..<image.height { for x in 0..<image.width { for c in 0..<3 {
                let amount = params.strength[c] * params.halationAmount
                image[x, y, c] += amount * accumulated[x, y, c]
                if params.renormalize { image[x, y, c] /= (1 + amount) }
            }}}
        }
        return image
    }

    private static func linearInterp(_ q: Double, x: [Double], y: [Double]) -> Double {
        let n = min(x.count, y.count)
        guard n > 0 else { return 0 }
        if n == 1 { return y[0] }
        if q <= x[0] { return y[0] }
        if q >= x[n - 1] { return y[n - 1] }
        var lo = 0, hi = n
        while lo < hi {
            let mid = (lo + hi) / 2
            if x[mid] <= q { lo = mid + 1 } else { hi = mid }
        }
        let i = max(0, min(lo - 1, n - 2))
        let dx = x[i + 1] - x[i]
        return dx == 0 ? y[i + 1] : y[i] + (q - x[i]) / dx * (y[i + 1] - y[i])
    }

    private static func poisson(_ lambda: Double, _ rng: inout SplitMix64) -> Int {
        if lambda < 30 {
            let threshold = exp(-lambda)
            var k = 0, p = 1.0
            repeat { k += 1; p *= max(rng.uniform(), 1e-15) } while p > threshold
            return max(k - 1, 0)
        }
        return max(Int((lambda + sqrt(lambda) * rng.normal()).rounded()), 0)
    }

    private static func binomial(_ n: Int, _ p: Double, _ rng: inout SplitMix64) -> Int {
        if n <= 64 {
            var k = 0
            for _ in 0..<n { if rng.uniform() < p { k += 1 } }
            return k
        }
        let mean = Double(n) * p
        let variance = Double(n) * p * (1 - p)
        return min(max(Int((mean + sqrt(max(variance, 0)) * rng.normal()).rounded()), 0), n)
    }
}
