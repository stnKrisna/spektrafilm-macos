import Foundation

enum GamutCompression {
    private static let m16: ColorScience.Mat3 = [
        [0.401288, 0.650173, -0.051461],
        [-0.250268, 1.204414, 0.045854],
        [-0.002079, 0.048952, 0.953127]
    ]
    private static let m16Inv = ColorScience.inverse(m16)
    private static let m1: ColorScience.Mat3 = [
        [460.0, 451.0, 288.0],
        [460.0, -891.0, -261.0],
        [460.0, -220.0, -6300.0]
    ]

    private struct Env {
        let c: Double, nc: Double, fl: Double, flRoot: Double, n: Double, z: Double, nbb: Double, ncb: Double
        let dRGB: SIMD3<Double>, dRGBInv: SIMD3<Double>, aw: Double
        let c1 = 0.007, c2 = 0.0228
    }

    static func compress(_ image: LinearRGBImage, colorSpace: String, parameters: OutputGamutCompressionParameters) -> LinearRGBImage {
        AppLog.debug("diag", "gamut compress active=\(parameters.active) cs=\(colorSpace)")
        guard parameters.active else { return image }
        // Golden/upstream default output is sRGB (D65). Keep this path exact and
        // fall back to identity for unsupported spaces until their CAM16 tables land.
        guard colorSpace.lowercased() == "srgb" else { return image }
        // The CAM16 viewing environment and sRGB gamut boundary are invariant.
        // Building the 64×720×18-bisection boundary table per render used to
        // dominate tiny profile-thumbnail renders (~0.5 s each). Cache it once.
        let env = cachedEnv
        let jpWhite = cachedJPWhite
        let cmax = cachedCMax
        var out = image
        for y in 0..<image.height { for x in 0..<image.width {
            let rgb = SIMD3(image[x,y,0], image[x,y,1], image[x,y,2])
            let xyz = ColorScience.mul(ColorScience.sRGBToXYZ, rgb)
            var jab = xyzToCAM16UCS(xyz, env: env)
            jab.x = compressLightness(jab.x, white: jpWhite)
            let cp = hypot(jab.y, jab.z)
            if x == 0 && y == 0 { AppLog.debug("diag", "gamut jab=\(jab.x),\(jab.y),\(jab.z) cp=\(cp) white=\(jpWhite)") }
            if cp > 1e-12 {
                let h = atan2(jab.z, jab.y)
                let boundary = max(cMaxLookup(jp: jab.x, h: h, table: cmax), 1e-9)
                let d = cp / boundary
                if x == 0 && y == 0 { AppLog.debug("diag", "gamut h=\(h) boundary=\(boundary) d=\(d)") }
                let dc = knee(d, threshold: parameters.threshold, limit: parameters.limit, power: parameters.power)
                let cn = dc * boundary
                jab.y = cn * cos(h); jab.z = cn * sin(h)
            }
            let xyzNew = cam16UCSToXYZ(jab, env: env)
            let rgbNew = ColorScience.mul(ColorScience.xyzToSRGB, xyzNew)
            out[x,y,0] = rgbNew.x; out[x,y,1] = rgbNew.y; out[x,y,2] = rgbNew.z
        }}
        return out
    }


    private struct CMaxTable {
        let nL: Int
        let nH: Int
        let minL: Double
        let maxL: Double
        let values: [Double]
    }

    private static let cachedEnv: Env = makeEnv()
    private static let cachedJPWhite: Double = xyzToCAM16UCS(ColorScience.d65, env: cachedEnv).x
    private static let cachedCMax: CMaxTable = makeCMaxTable(env: cachedEnv)

    /// Float32 payload consumed by the interactive Metal gamut-compression path.
    /// It is derived from the exact same cached CAM16 environment and gamut table
    /// as the Double reference implementation above.
    struct MetalPayload: Sendable {
        let fl: Float
        let flRoot: Float
        let n: Float
        let z: Float
        let nbb: Float
        let ncb: Float
        let c: Float
        let nc: Float
        let aw: Float
        let dRGB: SIMD3<Float>
        let dRGBInv: SIMD3<Float>
        let jpWhite: Float
        let nL: Int
        let nH: Int
        let minL: Float
        let maxL: Float
        let cMax: [Float]
    }

    static let metalPayload: MetalPayload = {
        let e = cachedEnv
        return MetalPayload(
            fl: Float(e.fl), flRoot: Float(e.flRoot), n: Float(e.n), z: Float(e.z),
            nbb: Float(e.nbb), ncb: Float(e.ncb), c: Float(e.c), nc: Float(e.nc),
            aw: Float(e.aw),
            dRGB: SIMD3(Float(e.dRGB.x), Float(e.dRGB.y), Float(e.dRGB.z)),
            dRGBInv: SIMD3(Float(e.dRGBInv.x), Float(e.dRGBInv.y), Float(e.dRGBInv.z)),
            jpWhite: Float(cachedJPWhite), nL: cachedCMax.nL, nH: cachedCMax.nH,
            minL: Float(cachedCMax.minL), maxL: Float(cachedCMax.maxL),
            cMax: cachedCMax.values.map(Float.init)
        )
    }()

    /// Mirrors upstream `_build_polar_perceptual_c_max_table` for CAM16-UCS:
    /// 64 J' samples from 1...110, 720 periodic hue samples on [-pi, pi),
    /// and 18 bisection steps starting from Cp=150.
    private static func makeCMaxTable(env: Env) -> CMaxTable {
        let nL = 64, nH = 720, minL = 1.0, maxL = 110.0
        var values = [Double](repeating: 0, count: nL * nH)
        for li in 0..<nL {
            let jp = minL + (maxL - minL) * Double(li) / Double(nL - 1)
            for hi in 0..<nH {
                let h = -Double.pi + 2 * Double.pi * Double(hi) / Double(nH)
                var lo = 0.0, upper = 150.0
                for _ in 0..<18 {
                    let mid = (lo + upper) * 0.5
                    let xyz = cam16UCSToXYZ(SIMD3(jp, mid * cos(h), mid * sin(h)), env: env)
                    let rgb = ColorScience.mul(ColorScience.xyzToSRGB, xyz)
                    let inside = rgb.x >= -1e-6 && rgb.x <= 1.000001 &&
                                 rgb.y >= -1e-6 && rgb.y <= 1.000001 &&
                                 rgb.z >= -1e-6 && rgb.z <= 1.000001
                    if inside { lo = mid } else { upper = mid }
                }
                values[li * nH + hi] = lo
            }
        }
        return CMaxTable(nL: nL, nH: nH, minL: minL, maxL: maxL, values: values)
    }

    /// Mirrors upstream `_c_max_lookup`, including clamping J' to the table
    /// extent and wrapping hue periodically across -pi/+pi.
    private static func cMaxLookup(jp: Double, h: Double, table: CMaxTable) -> Double {
        let l = min(max(jp, table.minL), table.maxL)
        let hStep = 2 * Double.pi / Double(table.nH)
        let rawHIndex = (h + Double.pi) / hStep
        let hFloor = floor(rawHIndex)
        let hFrac = rawHIndex - hFloor
        let hlo = ((Int(hFloor) % table.nH) + table.nH) % table.nH
        let hhi = (hlo + 1) % table.nH

        let rawLIndex = (l - table.minL) / (table.maxL - table.minL) * Double(table.nL - 1)
        let lFloor = floor(rawLIndex)
        let llo = min(max(Int(lFloor), 0), table.nL - 2)
        let lhi = llo + 1
        let lFrac = rawLIndex - Double(llo)

        let v00 = table.values[llo * table.nH + hlo]
        let v01 = table.values[llo * table.nH + hhi]
        let v10 = table.values[lhi * table.nH + hlo]
        let v11 = table.values[lhi * table.nH + hhi]
        return v00 * (1-lFrac) * (1-hFrac)
             + v01 * (1-lFrac) * hFrac
             + v10 * lFrac * (1-hFrac)
             + v11 * lFrac * hFrac
    }

    private static func makeEnv() -> Env {
        let xyzW = ColorScience.d65 * 100.0
        let rgbW = ColorScience.mul(m16, xyzW)
        let f = 1.0, c = 0.69, nc = 1.0, la = 64.0, yb = 20.0, yw = 100.0
        let k = 1.0 / (5.0 * la + 1.0), k4 = pow(k, 4)
        let fl = k4 * la + 0.1 * pow(1.0 - k4, 2) * pow(5.0 * la, 1.0/3.0)
        let n = yb / yw, z = 1.48 + sqrt(n), nbb = 0.725 * pow(n, -0.2)
        let d = min(max(f * (1.0 - (1.0/3.6) * exp((-la - 42.0) / 92.0)), 0), 1)
        let dr = SIMD3(1 + d * (yw / rgbW.x - 1), 1 + d * (yw / rgbW.y - 1), 1 + d * (yw / rgbW.z - 1))
        let rgbCW = SIMD3(rgbW.x*dr.x, rgbW.y*dr.y, rgbW.z*dr.z)
        let rgbAW = adapt(rgbCW, fl: fl)
        let aw = nbb * (2*rgbAW.x + rgbAW.y + 0.05*rgbAW.z - 0.305)
        return Env(c:c,nc:nc,fl:fl,flRoot:pow(fl,0.25),n:n,z:z,nbb:nbb,ncb:nbb,dRGB:dr,dRGBInv:SIMD3(1/dr.x,1/dr.y,1/dr.z),aw:aw)
    }

    private static func xyzToCAM16UCS(_ xyz: SIMD3<Double>, env: Env) -> SIMD3<Double> {
        var cone = ColorScience.mul(m16, xyz * 100.0)
        cone = SIMD3(cone.x*env.dRGB.x, cone.y*env.dRGB.y, cone.z*env.dRGB.z)
        let ra = adapt(cone, fl: env.fl)
        let a = ra.x + (-12*ra.y + ra.z)/11
        let b = (ra.x + ra.y - 2*ra.z)/9
        let h = atan2(b,a)
        let et = 0.25 * (cos(h + 2) + 3.8)
        let A = env.nbb * (2*ra.x + ra.y + 0.05*ra.z - 0.305)
        let jRoot = signedPow(A/env.aw, 0.5*env.c*env.z)
        let J = 100*jRoot*jRoot
        let denom = ra.x + ra.y + 1.05*ra.z
        let t = (50000.0/13.0 * env.nc * env.ncb * et * hypot(a,b)) / denom
        let alpha = signedPow(t, 0.9) * pow(1.64 - pow(0.29, env.n), 0.73)
        let C = alpha*jRoot
        let M = C*env.flRoot
        let mp = log(1 + env.c2*M)/env.c2
        let jp = (1 + 100*env.c1)*J/(1 + env.c1*J)
        return SIMD3(jp, mp*cos(h), mp*sin(h))
    }

    private static func cam16UCSToXYZ(_ jab: SIMD3<Double>, env: Env) -> SIMD3<Double> {
        let mp = hypot(jab.y,jab.z)
        let h = atan2(jab.z,jab.y)
        let M = (exp(mp*env.c2)-1)/env.c2
        let J = jab.x / (1 - env.c1*(jab.x - 100))
        if J <= 0 { return SIMD3(repeating: 0) }
        let jRoot = sqrt(J)*0.1
        let alpha = (M/env.flRoot)/max(jRoot,1e-20)
        let t = signedPow(alpha * pow(1.64 - pow(0.29,env.n), -0.73), 10.0/9.0)
        let et = 0.25*(cos(h+2)+3.8)
        let A = env.aw * signedPow(jRoot, 2/(env.c*env.z))
        let p1 = 50000.0/13.0 * env.nc*env.ncb*et
        // CAM16 inverse achromatic response includes the +0.305 offset.
        // The previous port omitted it from the response-vector matrix while
        // compensating only in the radius expression, so forward/inverse were
        // not true inverses and gamut-boundary searches were wrong.
        let p2 = A/env.nbb + 0.305
        let r = 23*p2*t / (23*p1 + t*(11*cos(h)+108*sin(h)))
        let a = r*cos(h), b = r*sin(h)
        let tmp = ColorScience.mul(m1, SIMD3(p2,a,b)) / 1403.0
        let rgbC = unadapt(tmp, fl: env.fl)
        let rgb = SIMD3(rgbC.x*env.dRGBInv.x, rgbC.y*env.dRGBInv.y, rgbC.z*env.dRGBInv.z)
        return ColorScience.mul(m16Inv, rgb) / 100.0
    }

    private static func boundaryChroma(jp: Double, h: Double, env: Env) -> Double {
        var lo = 0.0, hi = 150.0
        for _ in 0..<18 {
            let mid = (lo+hi)*0.5
            let xyz = cam16UCSToXYZ(SIMD3(jp,mid*cos(h),mid*sin(h)), env: env)
            let rgb = ColorScience.mul(ColorScience.xyzToSRGB, xyz)
            let ok = rgb.x >= -1e-6 && rgb.x <= 1.000001 && rgb.y >= -1e-6 && rgb.y <= 1.000001 && rgb.z >= -1e-6 && rgb.z <= 1.000001
            if ok { lo = mid } else { hi = mid }
        }
        return lo
    }

    private static func adapt(_ v: SIMD3<Double>, fl: Double) -> SIMD3<Double> {
        func f(_ c: Double) -> Double { let x = pow(fl*abs(c)*0.01,0.42); return copysign(400*x/(x+27.13),c) + 0.1 }
        return SIMD3(f(v.x),f(v.y),f(v.z))
    }
    private static func unadapt(_ v: SIMD3<Double>, fl: Double) -> SIMD3<Double> {
        let constant = 100/fl * pow(27.13,1/0.42)
        func f(_ c: Double) -> Double { let q = c - 0.1; let a = min(abs(q),399.999999); return copysign(constant*pow(a/(400-a),1/0.42),q) }
        return SIMD3(f(v.x),f(v.y),f(v.z))
    }
    private static func signedPow(_ x: Double, _ p: Double) -> Double { copysign(pow(abs(x),p),x) }
    private static func knee(_ d: Double, threshold: Double, limit: Double, power: Double) -> Double {
        guard d > threshold else { return d }; let scale=limit-threshold; let n=(d-threshold)/scale
        return threshold + scale*n/pow(1+pow(n,power),1/power)
    }
    private static func compressLightness(_ j: Double, white: Double) -> Double { knee(j/white,threshold:0.7,limit:1,power:2.2)*white }
}