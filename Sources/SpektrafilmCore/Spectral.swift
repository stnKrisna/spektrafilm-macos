import Foundation

public struct TCLUT: Sendable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public let data: [Double]

    public func sample(tx: Double, ty: Double) -> [Double] {
        // SFS2/TC LUT storage is [tc0][tc1][channel], flattened with tc1
        // contiguous: (i * size + j) * channels. Keep that axis order here.
        let i = min(max(tx, 0), 1) * Double(height - 1)
        let j = min(max(ty, 0), 1) * Double(width - 1)
        return Bicubic.sample(data: data, firstDim: height, secondDim: width, channels: channels, x: i, y: j)
    }
}

public enum Bicubic {
    public static func sample(data: [Double], firstDim: Int, secondDim: Int, channels: Int, x: Double, y: Double) -> [Double] {
        let maxX=Double(firstDim-1), maxY=Double(secondDim-1), xf=min(max(x,0),maxX), yf=min(max(y,0),maxY)
        let xi = xf >= maxX ? firstDim-2 : Int(xf), yi = yf >= maxY ? secondDim-2 : Int(yf)
        let fx=xf-Double(xi), fy=yf-Double(yi)
        let wx=[weight(fx+1),weight(fx),weight(fx-1),weight(fx-2)]
        let wy=[weight(fy+1),weight(fy),weight(fy-1),weight(fy-2)]
        var result=Array(repeating:0.0,count:channels), ws=0.0
        for i in 0..<4 { let xx=reflect(xi+i-1,firstDim); for j in 0..<4 { let yy=reflect(yi+j-1,secondDim); let w=wx[i]*wy[j]; ws += w; let base=(xx*secondDim+yy)*channels; for c in 0..<channels { result[c] += w*data[base+c] } } }
        if ws != 0 { for c in 0..<channels { result[c] /= ws } }
        return result
    }
    private static func weight(_ t:Double)->Double { let b=1.0/3,c=1.0/3,x=abs(t); if x<1 { return ((12-9*b-6*c)*x*x*x+(-18+12*b+6*c)*x*x+(6-2*b))/6 }; if x<2 { return ((-b-6*c)*x*x*x+(6*b+30*c)*x*x+(-12*b-48*c)*x+(8*b+24*c))/6 }; return 0 }
    private static func reflect(_ i:Int,_ n:Int)->Int { i<0 ? -i : (i>=n ? 2*(n-1)-i : i) }
}

public enum ColorScience {
    public typealias Mat3 = [[Double]]
    public static let sRGBToXYZ: Mat3=[[0.4123907992659595,0.35758433938387796,0.1804807884018343],[0.21263900587151036,0.7151686787677559,0.07219231536073371],[0.01933081871559185,0.11919477979462599,0.9505321522496607]]
    public static let xyzToSRGB: Mat3=[[3.2409699419045226,-1.537383177570094,-0.4986107602930034],[-0.9692436362808798,1.8759675015077202,0.04155505740717559],[0.05563007969699361,-0.20397695888897652,1.0569715142428786]]
    public static let d65=SIMD3<Double>(0.9504559270516716,1.0,1.0890577507598784)
    private static let cat02: Mat3=[[0.7328,0.4296,-0.1624],[-0.7036,1.6975,0.0061],[0.003,0.0136,0.9834]]
    private static let cat02Inv: Mat3=[[1.096123820835514,-0.278869000218287,0.182745179382773],[0.454369041975359,0.473533154307412,0.072097803717229],[-0.009627608738429,-0.005698031216113,1.015325639954543]]
    private static let cat16: Mat3=[[0.401288,0.650173,-0.051461],[-0.250268,1.204414,0.045854],[-0.002079,0.048952,0.953127]]
    private static let cat16Inv: Mat3=[[1.862067855087233,-1.011254630531684,0.149186775444451],[0.387526543236137,0.621447441931475,-0.008973985167612],[-0.015841498849333,-0.034122938028515,1.049964436877850]]
    public static func mul(_ m:Mat3,_ v:SIMD3<Double>)->SIMD3<Double> { SIMD3(m[0][0]*v.x+m[0][1]*v.y+m[0][2]*v.z,m[1][0]*v.x+m[1][1]*v.y+m[1][2]*v.z,m[2][0]*v.x+m[2][1]*v.y+m[2][2]*v.z) }
    public static func mul(_ a:Mat3,_ b:Mat3)->Mat3 { var r=Array(repeating:Array(repeating:0.0,count:3),count:3); for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { r[i][j] += a[i][k]*b[k][j] } } }; return r }
    public static func adaptation(src:SIMD3<Double>,dst:SIMD3<Double>)->Mat3 { let s=mul(cat02,src),d=mul(cat02,dst); let g=[d.x/s.x,d.y/s.y,d.z/s.z]; let dg:Mat3=[[g[0],0,0],[0,g[1],0],[0,0,g[2]]]; return mul(cat02Inv,mul(dg,cat02)) }
    public static func adaptationCAT16(src:SIMD3<Double>,dst:SIMD3<Double>)->Mat3 { let s=mul(cat16,src),d=mul(cat16,dst); let g=[d.x/s.x,d.y/s.y,d.z/s.z]; let dg:Mat3=[[g[0],0,0],[0,g[1],0],[0,0,g[2]]]; return mul(cat16Inv,mul(dg,cat16)) }
    public struct RGBSpace: Sendable { public let toXYZ: Mat3; public let white: SIMD3<Double> }
    public static func rgbSpace(_ name: String) -> RGBSpace {
        switch name.lowercased() {
        case "prophoto rgb", "prophoto":
            return .init(toXYZ:[[0.7977604896723027,0.13518583717574031,0.0313493495815248],[0.2880711282292934,0.7118432178101014,0.000085653960605259],[0.0,0.0,0.8251046025104601]], white:SIMD3(0.9642956764295677,1.0,0.8251046025104601))
        case "adobe rgb (1998)", "adobe rgb", "adobergb":
            return .init(toXYZ:[[0.5767309,0.1855540,0.1881852],[0.2973769,0.6273491,0.0752741],[0.0270343,0.0706872,0.9911085]], white:d65)
        case "display p3", "p3":
            return .init(toXYZ:[[0.48657095,0.26566769,0.19821729],[0.22897456,0.69173852,0.07928691],[0.0,0.04511338,1.04394437]], white:d65)
        case "itu-r bt.2020", "rec.2020", "bt.2020", "bt2020":
            return .init(toXYZ:[[0.63695805,0.14461690,0.16888098],[0.26270021,0.67799807,0.05930172],[0.0,0.02807269,1.06098506]], white:d65)
        case "acescg":
            return .init(toXYZ:[[0.66245418,0.13400421,0.15618769],[0.27222872,0.67408177,0.05368952],[-0.00557465,0.00406073,1.01033910]], white:SIMD3(0.95264607,1.0,1.00882518))
        default:
            return .init(toXYZ:sRGBToXYZ, white:d65)
        }
    }
    public static func inverse(_ m: Mat3) -> Mat3 {
        let a=m[0][0],b=m[0][1],c=m[0][2],d=m[1][0],e=m[1][1],f=m[1][2],g=m[2][0],h=m[2][1],i=m[2][2]
        let A = e*i-f*h
        let B = -(d*i-f*g)
        let C = d*h-e*g
        let D = -(b*i-c*h)
        let E = a*i-c*g
        let F = -(a*h-b*g)
        let G = b*f-c*e
        let H = -(a*f-c*d)
        let I = a*e-b*d
        let det = a*A+b*B+c*C
        guard abs(det)>1e-18 else { return xyzToSRGB }
        return [[A/det,D/det,G/det],[B/det,E/det,H/det],[C/det,F/det,I/det]]
    }
    public static func xyToTC(_ x:Double,_ y:Double)->(Double,Double) { let q=max(1-x,1e-10); return (min(max(q*q,0),1),min(max(y/q,0),1)) }
    public static func tcToXY(_ tx:Double,_ ty:Double)->(Double,Double) { let q=sqrt(max(tx,0)); return (1-q,ty*q) }
}

public enum SpectralService {
    public static func sensitivity(profile: FilmProfile) -> [[Double]] {
        let raw=profile.data.rawLogSensitivity
        if !raw.isEmpty { return raw.map { row in (0..<3).map { c in c<row.count ? (row[c].map { pow(10,$0) } ?? 0) : 0 } } }
        return profile.data.logSensitivity.map { row in (0..<3).map { c in c<row.count ? pow(10,row[c]) : 0 } }
    }

    public static func computeTCLUT(spectra: SpectraLUT, profile: FilmProfile, illuminant: [Double], sensitivityOverride: [[Double]]? = nil) -> TCLUT {
        let sens=sensitivityOverride ?? sensitivity(profile:profile), n=min(spectra.wavelengthCount,min(sens.count,illuminant.count))
        var window=bandpass(profile.data.hanatosAdaptationWindowParameters,count:n)
        for c in 0..<3 {
            var num=[Double](),den=[Double](); num.reserveCapacity(n); den.reserveCapacity(n)
            for i in 0..<n { let q=sens[i][c]*illuminant[i]; num.append(q*window[i][c]); den.append(q) }
            let norm=pairwise(num)/max(pairwise(den),1e-30); if norm>1e-10 { for i in 0..<n { window[i][c] /= norm } }
        }
        // This runs once per film/profile/filter combination. The old port
        // allocated ~110k temporary [Double] arrays (one for every LUT cell
        // and channel) and then pairwise-summed them. That made the first
        // thumbnail for every film stock take seconds even for an 85×128 image.
        // Precompute the three spectral weights and accumulate directly. The
        // only numerical difference is floating-point summation order (~ulp).
        var weights = [SIMD3<Double>](repeating: .zero, count: n)
        for i in 0..<n {
            weights[i] = SIMD3(
                sens[i][0] * window[i][0],
                sens[i][1] * window[i][1],
                sens[i][2] * window[i][2]
            )
        }
        var out=Array(repeating:0.0,count:spectra.width*spectra.height*3)
        for y in 0..<spectra.height {
            for x in 0..<spectra.width {
                var sum = SIMD3<Double>(repeating: 0)
                for i in 0..<n {
                    sum += weights[i] * Double(spectra.value(x:x,y:y,wavelength:i))
                }
                let base=(y*spectra.width+x)*3
                out[base]=sum.x; out[base+1]=sum.y; out[base+2]=sum.z
            }
        }
        return .init(width:spectra.width,height:spectra.height,channels:3,data:out)
    }

    public static func rgbToFilmRaw(_ image: LinearRGBImage, profile: FilmProfile, resources: PipelineResources, camera: CameraParameters? = nil, inputColorSpace: String = "sRGB", inputGamutCompression: InputGamutCompressionParameters = .init(), useGPU: Bool = false) -> LinearRGBImage {
        let target=resources.pack.xyzWhite(for: profile.info.referenceIlluminant)
        let sourceSpace=ColorScience.rgbSpace(inputColorSpace)
        let adapt=ColorScience.adaptationCAT16(src:sourceSpace.white,dst:target)
        var sensOverride: [[Double]]? = nil
        var suffix = ""
        if let camera {
            let filtered = filteredCameraSensitivity(profile: profile, resources: resources, uv: camera.filterUV, ir: camera.filterIR)
            if filtered.didFilter {
                sensOverride = filtered.sensitivity
                suffix = "uv=\(camera.filterUV);ir=\(camera.filterIR)"
            }
        }
        let lut=resources.tcLUT(for: profile, sensitivityOverride: sensOverride, cacheSuffix: suffix)
        if useGPU, let accelerated = MetalAccelerator.shared.rgbToFilmRaw(image, lut: lut, sourceToXYZ: sourceSpace.toXYZ, adaptation: adapt, cacheKey: "\(profile.id):\(suffix)") {
            return accelerated
        }
        var out=LinearRGBImage(width:image.width,height:image.height)
        for y in 0..<image.height { for x in 0..<image.width {
            let rgb=SIMD3(image[x,y,0],image[x,y,1],image[x,y,2])
            // Keep the two matrix multiplies separate. The Rust parity path does this
            // intentionally because combining the matrices changes f64 operation order.
            let xyzNative=ColorScience.mul(sourceSpace.toXYZ,rgb)
            let xyz=ColorScience.mul(adapt,xyzNative)
            let brightness=xyz.x+xyz.y+xyz.z
            if brightness<=1e-10 { out[x,y,0]=0;out[x,y,1]=0;out[x,y,2]=0;continue }
            var chromaX=xyz.x/brightness, chromaY=xyz.y/brightness
            if inputGamutCompression.active {
                let whiteSum = target.x + target.y + target.z
                let whiteXY = SIMD2(target.x / whiteSum, target.y / whiteSum)
                let compressed = compressXYRadial(SIMD2(chromaX, chromaY), white: whiteXY, pack: resources.pack, params: inputGamutCompression)
                chromaX = compressed.x; chromaY = compressed.y
            }
            let tc=ColorScience.xyToTC(chromaX,chromaY), raw=lut.sample(tx:tc.0,ty:tc.1)
            // Upstream profiles pre-balance film sensitivity; the Hanatos LUT is
            // deliberately *not* mid-gray normalized on the per-pixel path.
            for c in 0..<3 { out[x,y,c]=max(raw[c]*brightness,1e-30) }
        }}
        return out
    }

    private static func compressXYRadial(_ xy: SIMD2<Double>, white: SIMD2<Double>, pack: SpektrafilmDataPack, params: InputGamutCompressionParameters) -> SIMD2<Double> {
        let delta = xy - white
        let dist = hypot(delta.x, delta.y)
        if dist < 1e-9 { return xy }
        let dir = delta / dist
        var polygon = pack.spectralLocusXY.compactMap { row -> SIMD2<Double>? in
            guard row.count >= 2 else { return nil }
            return SIMD2(row[0], row[1])
        }
        guard polygon.count >= 3 else { return xy }
        if polygon.first != polygon.last { polygon.append(polygon[0]) }
        var boundary = Double.infinity
        for i in 0..<(polygon.count - 1) {
            let a = polygon[i], e = polygon[i + 1] - a
            let denom = dir.x * e.y - dir.y * e.x
            if abs(denom) <= 1e-12 { continue }
            let ox = white.x - a.x, oy = white.y - a.y
            let t = (-ox * e.y + oy * e.x) / denom
            let u = (-ox * dir.y + oy * dir.x) / denom
            if t > 1e-9 && u >= 0 && u <= 1 { boundary = min(boundary, t) }
        }
        guard boundary.isFinite else { return xy }
        let d = dist / max(boundary, 1e-12)
        let dc: Double
        if d <= params.threshold { dc = d }
        else {
            let scale = params.limit - params.threshold
            let n = (d - params.threshold) / scale
            dc = params.threshold + scale * n / pow(1 + pow(n, params.power), 1 / params.power)
        }
        return white + dir * (dc * boundary)
    }


    public static func filteredCameraSensitivity(profile: FilmProfile, resources: PipelineResources, uv: [Double], ir: [Double]) -> (sensitivity: [[Double]], didFilter: Bool) {
        var sens = sensitivity(profile: profile)
        let n = min(resources.pack.wavelengths.count, sens.count)
        guard n > 0 else { return (sens, false) }
        let uvAmp = min(max(uv.count > 0 ? uv[0] : 0, 0), 1), irAmp = min(max(ir.count > 0 ? ir[0] : 0, 0), 1)
        guard uvAmp != 0 || irAmp != 0 else { return (sens, false) }
        let uvCenter = uv.count > 1 ? uv[1] : 410, uvWidth = max(abs(uv.count > 2 ? uv[2] : 8), 1e-12)
        let irCenter = ir.count > 1 ? ir[1] : 675, irWidth = max(abs(ir.count > 2 ? ir[2] : 15), 1e-12)
        let illum = resources.pack.illuminant(profile.info.referenceIlluminant)
        var filter = [Double](repeating: 1, count: n)
        for i in 0..<n {
            let wl = resources.pack.wavelengths[i]
            let uvStep = 0.5 * (1 + erf((wl - uvCenter) / uvWidth))
            let irStep = 0.5 * (1 + erf((wl - irCenter) / -irWidth))
            let fuv = 1 - uvAmp + uvAmp * uvStep
            let fir = 1 - irAmp + irAmp * irStep
            filter[i] = fuv * fir
        }
        for c in 0..<3 {
            var before = 0.0, after = 0.0
            for i in 0..<n {
                let e = i < illum.count ? illum[i] : 1
                before += sens[i][c] * e
                after += sens[i][c] * filter[i] * e
            }
            let normalization = after / max(before, 1e-30)
            if normalization > 1e-30 { for i in 0..<n { sens[i][c] *= filter[i] / normalization } }
        }
        return (sens, true)
    }
    /// Spectral printing: negative dye density -> transmitted enlarger light -> print raw exposure.
    /// Mirrors current Python PrintingStage: spectral negative transmission, calibrated
    /// mid-gray factor, filtered preflash, then user print exposure.
    public static func printExposure(
        _ negative: LinearRGBImage,
        film: FilmProfile,
        print: FilmProfile,
        resources: PipelineResources,
        parameters: EnlargerParameters,
        camera: CameraParameters = .init(),
        filmRendering: FilmRenderingParameters = .init(),
        inputColorSpace: String = "sRGB",
        useGPU: Bool = false
    ) -> LinearRGBImage? {
        let filmCD=film.data.channelDensity
        let printSensitivity=sensitivity(profile:print)
        let n=min(resources.pack.wavelengths.count,min(filmCD.count,printSensitivity.count))
        guard n > 0 else { return nil }
        let lightSource=resources.pack.illuminant(parameters.illuminant)
        let printIlluminant=filteredEnlargerIlluminant(lightSource, resources: resources,
            c: parameters.cFilterNeutral,
            m: parameters.mFilterNeutral + parameters.mFilterShift,
            y: parameters.yFilterNeutral + parameters.yFilterShift)

        // Python computes both a neutral-midgray baseline and an exposure-compensated
        // neutral midgray, then chooses a factor from normalize/compensation flags.
        let neutral=LinearRGBImage(width:1,height:1,pixels:[0.184,0.184,0.184])
        let neutralRaw=rgbToFilmRaw(neutral, profile:film, resources:resources, camera:camera, inputColorSpace:"sRGB")
        // Upstream print balancing intentionally uses develop_simple() on the
        // stock's *unnormalized* density curves, then adds base density during
        // the spectral density conversion. The main negative development path
        // is normalized, so using FilmModels.develop(profile:) here double-shifts
        // the reference and produces a strong color cast in print scans.
        let neutralDensity=FilmModels.develop(
            logExposure: neutralRaw.mapped{log10(max($0,0)+1e-10)},
            logExposureAxis: film.data.logExposure,
            densityCurves: film.data.densityCurves,
            gamma: filmRendering.densityCurveGamma)
        var compensatedRaw=neutralRaw
        compensatedRaw.mapInPlace { $0 * pow(2,camera.exposureCompensationEV) }
        let compensatedDensity=FilmModels.develop(
            logExposure: compensatedRaw.mapped{log10(max($0,0)+1e-10)},
            logExposureAxis: film.data.logExposure,
            densityCurves: film.data.densityCurves,
            gamma: filmRendering.densityCurveGamma)
        let baselineFactor=exposureFactor(density:neutralDensity, film:film, printSensitivity:printSensitivity, illuminant:printIlluminant, n:n)
        let compensatedFactor=exposureFactor(density:compensatedDensity, film:film, printSensitivity:printSensitivity, illuminant:printIlluminant, n:n)
        let exposureFactorMidgray: Double
        if parameters.printExposureCompensation && !parameters.normalizePrintExposure {
            exposureFactorMidgray=compensatedFactor/max(baselineFactor,1e-30)
        } else if parameters.normalizePrintExposure && parameters.printExposureCompensation {
            exposureFactorMidgray=compensatedFactor
        } else if parameters.normalizePrintExposure {
            exposureFactorMidgray=baselineFactor
        } else {
            exposureFactorMidgray=1
        }

        let preflash=preflashRaw(film:film, sensitivity:printSensitivity, lightSource:lightSource, resources:resources, parameters:parameters, n:n)
        if useGPU, let accelerated = MetalAccelerator.shared.printExposure(
            negative,
            channelDensity: filmCD,
            baseDensity: film.data.baseDensityRows,
            sensitivity: printSensitivity,
            illuminant: printIlluminant,
            preflash: preflash,
            scale: exposureFactorMidgray * parameters.printExposure,
            cacheKey: "\(film.id)->\(print.id):\(parameters.illuminant):\(parameters.cFilterNeutral):\(parameters.mFilterNeutral + parameters.mFilterShift):\(parameters.yFilterNeutral + parameters.yFilterShift)"
        ) { return accelerated }
        var out=LinearRGBImage(width:negative.width,height:negative.height)
        for y in 0..<negative.height { for x in 0..<negative.width {
            let raw=integratedPrintRaw(density:negative,x:x,y:y,film:film,sensitivity:printSensitivity,illuminant:printIlluminant,n:n)
            for c in 0..<3 { out[x,y,c]=max((raw[c]*exposureFactorMidgray + preflash[c])*parameters.printExposure,1e-30) }
        }}
        return out
    }

    private static func exposureFactor(density:LinearRGBImage,film:FilmProfile,printSensitivity:[[Double]],illuminant:[Double],n:Int)->Double {
        let raw=integratedPrintRaw(density:density,x:0,y:0,film:film,sensitivity:printSensitivity,illuminant:illuminant,n:n)
        let geo=exp(raw.map{log(max($0,1e-10))}.reduce(0,+)/3.0)
        return 1/max(geo,1e-30)
    }

    private static func integratedPrintRaw(density:LinearRGBImage,x:Int,y:Int,film:FilmProfile,sensitivity:[[Double]],illuminant:[Double],n:Int)->[Double] {
        var raw=[0.0,0.0,0.0]
        for i in 0..<n {
            // Upstream JSON nulls become NaN in NumPy. compute_density_spectral
            // propagates that NaN for the wavelength and density_to_light then
            // replaces the transmitted-light NaN with zero. Match that rather
            // than interpreting a missing dye-density sample as zero density.
            guard i < film.data.channelDensity.count,
                  film.data.channelDensity[i].count >= 3,
                  film.data.channelDensity[i][0] != nil,
                  film.data.channelDensity[i][1] != nil,
                  film.data.channelDensity[i][2] != nil else { continue }
            var d=0.0
            for c in 0..<3 { d += film.data.channelDensity[i][c]! * density[x,y,c] }
            if i<film.data.baseDensityRows.count {
                guard film.data.baseDensityRows[i].allSatisfy({ $0 != nil }) else { continue }
                for v in film.data.baseDensityRows[i] { d += v! }
            }
            let transmitted=pow(10,-d)*(i<illuminant.count ? illuminant[i] : 0)
            for c in 0..<3 { raw[c] += transmitted*sensitivity[i][c] }
        }
        return raw
    }

    private static func preflashRaw(film:FilmProfile,sensitivity:[[Double]],lightSource:[Double],resources:PipelineResources,parameters:EnlargerParameters,n:Int)->[Double] {
        guard parameters.preflashExposure>0 else { return [0,0,0] }
        let illum=filteredEnlargerIlluminant(lightSource, resources:resources,
            c:parameters.cFilterNeutral,
            m:parameters.mFilterNeutral+parameters.preflashMFilterShift,
            y:parameters.yFilterNeutral+parameters.preflashYFilterShift)
        var raw=[0.0,0.0,0.0]
        for i in 0..<n {
            var d=0.0
            if i<film.data.baseDensityRows.count { for v in film.data.baseDensityRows[i] { d += v ?? 0 } }
            let transmitted=pow(10,-d)*(i<illum.count ? illum[i] : 0)
            for c in 0..<3 { raw[c]+=transmitted*sensitivity[i][c]*parameters.preflashExposure }
        }
        return raw
    }

    private static func filteredEnlargerIlluminant(_ source:[Double],resources:PipelineResources,c:Double,m:Double,y:Double)->[Double] {
        var light=source
        let dichroics=resources.pack.dichroicFilters["custom"] ?? resources.pack.dichroicFilters["thorlabs"]
        let transmissions=[c,m,y].map{pow(10,-$0/100)}
        if let dichroics {
            let n=min(light.count,dichroics.count)
            for i in 0..<n {
                var f=1.0
                for ch in 0..<3 where ch<dichroics[i].count {
                    if let d=dichroics[i][ch] { f *= 1-(1-d)*(1-transmissions[ch]) }
                }
                light[i]*=f
            }
        }
        return light
    }


#if canImport(Metal)
    public static func printExposureResident(
        _ negative: MetalAccelerator.ResidentImage,
        film: FilmProfile,
        print: FilmProfile,
        resources: PipelineResources,
        parameters: EnlargerParameters,
        camera: CameraParameters = .init(),
        filmRendering: FilmRenderingParameters = .init()
    ) -> MetalAccelerator.ResidentImage? {
        let filmCD=film.data.channelDensity, printSensitivity=sensitivity(profile:print)
        let n=min(resources.pack.wavelengths.count,min(filmCD.count,printSensitivity.count));guard n>0 else{return nil}
        let lightSource=resources.pack.illuminant(parameters.illuminant)
        let printIlluminant=filteredEnlargerIlluminant(lightSource,resources:resources,c:parameters.cFilterNeutral,m:parameters.mFilterNeutral+parameters.mFilterShift,y:parameters.yFilterNeutral+parameters.yFilterShift)
        let neutral=LinearRGBImage(width:1,height:1,pixels:[0.184,0.184,0.184])
        let neutralRaw=rgbToFilmRaw(neutral,profile:film,resources:resources,camera:camera,inputColorSpace:"sRGB")
        let neutralDensity=FilmModels.develop(logExposure:neutralRaw.mapped{log10(max($0,0)+1e-10)},logExposureAxis:film.data.logExposure,densityCurves:film.data.densityCurves,gamma:filmRendering.densityCurveGamma)
        var compensatedRaw=neutralRaw;compensatedRaw.mapInPlace{$0*pow(2,camera.exposureCompensationEV)}
        let compensatedDensity=FilmModels.develop(logExposure:compensatedRaw.mapped{log10(max($0,0)+1e-10)},logExposureAxis:film.data.logExposure,densityCurves:film.data.densityCurves,gamma:filmRendering.densityCurveGamma)
        let baselineFactor=exposureFactor(density:neutralDensity,film:film,printSensitivity:printSensitivity,illuminant:printIlluminant,n:n),compensatedFactor=exposureFactor(density:compensatedDensity,film:film,printSensitivity:printSensitivity,illuminant:printIlluminant,n:n)
        let factor:Double
        if parameters.printExposureCompensation && !parameters.normalizePrintExposure { factor=compensatedFactor/max(baselineFactor,1e-30) }
        else if parameters.normalizePrintExposure && parameters.printExposureCompensation { factor=compensatedFactor }
        else if parameters.normalizePrintExposure { factor=baselineFactor }
        else { factor=1 }
        let preflash=preflashRaw(film:film,sensitivity:printSensitivity,lightSource:lightSource,resources:resources,parameters:parameters,n:n)
        return MetalAccelerator.shared.printExposureResident(negative,channelDensity:filmCD,baseDensity:film.data.baseDensityRows,sensitivity:printSensitivity,illuminant:printIlluminant,preflash:preflash,scale:factor*parameters.printExposure,cacheKey:"\(film.id)->\(print.id):\(parameters.illuminant):\(parameters.cFilterNeutral):\(parameters.mFilterNeutral + parameters.mFilterShift):\(parameters.yFilterNeutral + parameters.yFilterShift)")
    }

    public static func densityToRGBResident(
        _ density: MetalAccelerator.ResidentImage,
        profile: FilmProfile,
        resources: PipelineResources,
        outputColorSpace: String = "sRGB"
    ) -> MetalAccelerator.ResidentImage? {
        let cd=profile.data.channelDensity,base=profile.data.baseDensityRows
        guard cd.count>=resources.pack.wavelengths.count else{return nil}
        let illum=resources.pack.illuminant(profile.info.viewingIlluminant ?? profile.info.referenceIlluminant),cmf=resources.pack.cmfs,n=min(cd.count,min(illum.count,cmf.count))
        var white=SIMD3<Double>(repeating:0);for i in 0..<n where cmf[i].count>=3{white += SIMD3(cmf[i][0],cmf[i][1],cmf[i][2])*illum[i]}
        let norm=1/max(white.y,1e-20),outputSpace=ColorScience.rgbSpace(outputColorSpace),adapt=ColorScience.adaptation(src:white*norm,dst:outputSpace.white),xyzToOutput=ColorScience.inverse(outputSpace.toXYZ),transform=ColorScience.mul(xyzToOutput,adapt)
        return MetalAccelerator.shared.densityToRGBResident(density,channelDensity:cd,baseDensity:base,cmfs:cmf,illuminant:illum,norm:norm,transform:transform,cacheKey:"\(profile.id):\(profile.info.viewingIlluminant ?? profile.info.referenceIlluminant ?? "default")")
    }

    /// Fuses spectral density scanning, optional glare compositing and CAM16 output
    /// gamut compression into one Metal kernel. The result remains linear RGB and
    /// GPU-resident for scanner blur/unsharp/levels/CCTF finishing.
    public static func densityToRGBGamutResident(
        _ density: MetalAccelerator.ResidentImage,
        profile: FilmProfile,
        resources: PipelineResources,
        io: IOParameters,
        glare: GlareParameters?
    ) -> MetalAccelerator.ResidentImage? {
        let cd=profile.data.channelDensity,base=profile.data.baseDensityRows
        guard cd.count>=resources.pack.wavelengths.count else{return nil}
        let illum=resources.pack.illuminant(profile.info.viewingIlluminant ?? profile.info.referenceIlluminant),cmf=resources.pack.cmfs,n=min(cd.count,min(illum.count,cmf.count))
        var white=SIMD3<Double>(repeating:0);for i in 0..<n where cmf[i].count>=3{white += SIMD3(cmf[i][0],cmf[i][1],cmf[i][2])*illum[i]}
        let norm=1/max(white.y,1e-20),outputSpace=ColorScience.rgbSpace(io.outputColorSpace),adapt=ColorScience.adaptation(src:white*norm,dst:outputSpace.white),xyzToOutput=ColorScience.inverse(outputSpace.toXYZ),transform=ColorScience.mul(xyzToOutput,adapt),whiteRGB=ColorScience.mul(transform,white*norm)
        var glareResident: MetalAccelerator.ResidentImage?
        if let field=makeGlareField(width:density.width,height:density.height,parameters:glare,useGPU:true) {
            glareResident=MetalAccelerator.shared.uploadResident(field)
            if glareResident == nil { return nil }
        }
        return MetalAccelerator.shared.densityToRGBGamutResident(
            density, channelDensity:cd, baseDensity:base, cmfs:cmf, illuminant:illum, norm:norm, transform:transform,
            cacheKey:"\(profile.id):\(profile.info.viewingIlluminant ?? profile.info.referenceIlluminant ?? "default")",
            glareField:glareResident, glareWhiteRGB:whiteRGB, colorSpace:io.outputColorSpace, gamut:io.outputGamutCompression
        )
    }

    /// Adds the deterministic stochastic glare field while the scanned image is
    /// still GPU-resident. The field generation intentionally reuses the reference
    /// RNG semantics; only the compositing stays on Metal.
    public static func applyGlareResident(
        _ image: MetalAccelerator.ResidentImage,
        profile: FilmProfile,
        resources: PipelineResources,
        outputColorSpace: String,
        glare: GlareParameters?
    ) -> MetalAccelerator.ResidentImage? {
        guard let glareField = makeGlareField(width: image.width, height: image.height, parameters: glare, useGPU: true) else { return image }
        let illum = resources.pack.illuminant(profile.info.viewingIlluminant ?? profile.info.referenceIlluminant)
        let cmf = resources.pack.cmfs
        let n = min(illum.count, cmf.count)
        var white = SIMD3<Double>(repeating: 0)
        for i in 0..<n where cmf[i].count >= 3 { white += SIMD3(cmf[i][0], cmf[i][1], cmf[i][2]) * illum[i] }
        let norm = 1 / max(white.y, 1e-20)
        let outputSpace = ColorScience.rgbSpace(outputColorSpace)
        let adapt = ColorScience.adaptation(src: white * norm, dst: outputSpace.white)
        let xyzToOutput = ColorScience.inverse(outputSpace.toXYZ)
        let transform = ColorScience.mul(xyzToOutput, adapt)
        let whiteRGB = ColorScience.mul(transform, white * norm)
        guard let residentField = MetalAccelerator.shared.uploadResident(glareField) else { return nil }
        return MetalAccelerator.shared.addScaledResident(image, field: residentField, scale: whiteRGB)
    }

    /// Applies the same stochastic glare term after a resident spectral scan has
    /// been downloaded. This remains for non-resident callers and parity tests.
    public static func applyGlareToScannedRGB(_ image: LinearRGBImage, profile: FilmProfile, resources: PipelineResources, outputColorSpace: String, glare: GlareParameters?) -> LinearRGBImage {
        guard let glareField=makeGlareField(width:image.width,height:image.height,parameters:glare,useGPU:true) else{return image}
        let illum=resources.pack.illuminant(profile.info.viewingIlluminant ?? profile.info.referenceIlluminant),cmf=resources.pack.cmfs,n=min(illum.count,cmf.count)
        var white=SIMD3<Double>(repeating:0);for i in 0..<n where cmf[i].count>=3{white += SIMD3(cmf[i][0],cmf[i][1],cmf[i][2])*illum[i]}
        let norm=1/max(white.y,1e-20),outputSpace=ColorScience.rgbSpace(outputColorSpace),adapt=ColorScience.adaptation(src:white*norm,dst:outputSpace.white),xyzToOutput=ColorScience.inverse(outputSpace.toXYZ),transform=ColorScience.mul(xyzToOutput,adapt),whiteRGB=ColorScience.mul(transform,white*norm)
        var out=image;for y in 0..<out.height{for x in 0..<out.width{let g=glareField[x,y,0];out[x,y,0]+=whiteRGB.x*g;out[x,y,1]+=whiteRGB.y*g;out[x,y,2]+=whiteRGB.z*g}}
        return out
    }
#endif

    /// Convert spectral density to XYZ under the profile viewing illuminant and then to linear sRGB.
    public static func densityToRGB(_ density: LinearRGBImage, profile: FilmProfile, resources: PipelineResources, outputColorSpace: String = "sRGB", glare: GlareParameters? = nil, useGPU: Bool = false) -> LinearRGBImage? {
        let cd=profile.data.channelDensity, base=profile.data.baseDensityRows
        guard cd.count>=resources.pack.wavelengths.count else { return nil }
        let illum=resources.pack.illuminant(profile.info.viewingIlluminant ?? profile.info.referenceIlluminant), cmf=resources.pack.cmfs, n=min(cd.count,min(illum.count,cmf.count))
        var white=SIMD3<Double>(repeating:0); for i in 0..<n where cmf[i].count>=3 { white += SIMD3(cmf[i][0],cmf[i][1],cmf[i][2])*illum[i] }
        let norm=1/max(white.y,1e-20), outputSpace=ColorScience.rgbSpace(outputColorSpace), adapt=ColorScience.adaptation(src:white*norm,dst:outputSpace.white), xyzToOutput=ColorScience.inverse(outputSpace.toXYZ)
        let transform = ColorScience.mul(xyzToOutput, adapt)
        if useGPU, var accelerated = MetalAccelerator.shared.densityToRGB(
            density,
            channelDensity: cd,
            baseDensity: base,
            cmfs: cmf,
            illuminant: illum,
            norm: norm,
            transform: transform,
            cacheKey: "\(profile.id):\(profile.info.viewingIlluminant ?? profile.info.referenceIlluminant ?? "default")"
        ) {
            if let glareField = makeGlareField(width: density.width, height: density.height, parameters: glare, useGPU: true) {
                let whiteRGB = ColorScience.mul(transform, white * norm)
                for y in 0..<density.height { for x in 0..<density.width {
                    let g = glareField[x,y,0]
                    accelerated[x,y,0] += whiteRGB.x * g
                    accelerated[x,y,1] += whiteRGB.y * g
                    accelerated[x,y,2] += whiteRGB.z * g
                }}
            }
            return accelerated
        }
        var out=LinearRGBImage(width:density.width,height:density.height)
        let glareField = makeGlareField(width: density.width, height: density.height, parameters: glare, useGPU: false)
        for y in 0..<density.height { for x in 0..<density.width { var xyz=SIMD3<Double>(repeating:0)
            for i in 0..<n where cd[i].count>=3 && cmf[i].count>=3 {
                guard cd[i][0] != nil, cd[i][1] != nil, cd[i][2] != nil else { continue }
                var d=0.0; for c in 0..<3 { d += cd[i][c]! * density[x,y,c] }
                if i<base.count {
                    guard base[i].allSatisfy({ $0 != nil }) else { continue }
                    for v in base[i] { d += v! }
                }
                let t=pow(10,-d)*illum[i]; xyz += SIMD3(cmf[i][0],cmf[i][1],cmf[i][2])*t
            }
            xyz *= norm; if let glareField { xyz += white * norm * glareField[x,y,0] }; let rgb=ColorScience.mul(xyzToOutput,ColorScience.mul(adapt,xyz)); out[x,y,0]=rgb.x;out[x,y,1]=rgb.y;out[x,y,2]=rgb.z
        }}
        return out
    }

    private static func makeGlareField(width:Int,height:Int,parameters:GlareParameters?,useGPU:Bool)->LinearRGBImage? {
        guard let p=parameters, p.active, p.percent>0 else { return nil }
        let mean=p.percent, std=p.roughness*p.percent
        let sigma2=log(1+(std*std)/max(mean*mean,1e-30)), sigma=sqrt(max(sigma2,0)), mu=log(max(mean,1e-30))-sigma2/2
        var rng=SplitMix64(seed:p.seed), field=LinearRGBImage(width:width,height:height)
        for y in 0..<height { for x in 0..<width { let v=exp(mu+sigma*rng.normal())/100; for c in 0..<3 { field[x,y,c]=v } } }
        return p.blur>0 ? Convolution.gaussianBlur(field,sigma:p.blur,useGPU:useGPU) : field
    }

    public static func pairwise(_ xs:[Double])->Double { switch xs.count { case 0:return 0;case 1:return xs[0];case 2:return xs[0]+xs[1];default:let m=xs.count/2;return pairwise(Array(xs[..<m]))+pairwise(Array(xs[m...])) } }
    private static func bandpass(_ p:[Double],count:Int)->[[Double]] { guard p.count>=4 else{return Array(repeating:[1,1,1],count:count)}; let s=sqrt(2.0); return (0..<count).map { i in let wl=380+Double(i)*5; let a=0.5*(1+erf((wl-p[0])/(p[1]*s))),b=0.5*(1-erf((wl-p[2])/(p[3]*s))),w=a*b;return[w,w,w] } }
}
