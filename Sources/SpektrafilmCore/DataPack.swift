import Foundation

public struct SpektrafilmDataPack: Decodable, Sendable {
    public let packFormat: Int
    public let spektrafilmVersion: String
    public let wavelengths: [Double]
    public let logExposure: [Double]
    public let cmfs: [[Double]]
    public let spectralLocusXY: [[Double]]
    public let illuminants: [String: [Double]]
    public let dichroicFilters: [String: [[Double?]]]
    public let neutralPrintFilters: [String: [String: [String: [Double]]]]

    enum CodingKeys: String, CodingKey {
        case packFormat = "pack_format"
        case spektrafilmVersion = "spektrafilm_version"
        case wavelengths, logExposure = "log_exposure", cmfs
        case spectralLocusXY = "spectral_locus_xy"
        case illuminants
        case dichroicFilters = "dichroic_filters"
        case neutralPrintFilters = "neutral_print_filters"
    }

    public static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func illuminant(_ name: String?) -> [Double] {
        if let name, let v = illuminants[name] { return v }
        return illuminants["D55"] ?? illuminants["D50"] ?? Array(repeating: 1, count: wavelengths.count)
    }

    public func xyzWhite(for illuminantName: String?) -> SIMD3<Double> {
        let spd = illuminant(illuminantName)
        var xyz = SIMD3<Double>(repeating: 0)
        for i in 0..<min(spd.count, cmfs.count) where cmfs[i].count >= 3 {
            xyz.x += spd[i] * cmfs[i][0]
            xyz.y += spd[i] * cmfs[i][1]
            xyz.z += spd[i] * cmfs[i][2]
        }
        guard xyz.y > 1e-15 else { return SIMD3(0.95047, 1, 1.08883) }
        return xyz / xyz.y
    }
}

public enum SpectralLUTError: Error, LocalizedError {
    case malformed(String)
    public var errorDescription: String? {
        switch self { case .malformed(let s): return "Malformed Spektrafilm spectral LUT: \(s)" }
    }
}

/// Reader for darktable-spektrafilm's compact `SFS2` LUT container.
/// Payload is little-endian IEEE-754 binary16 with shape H×W×81.
public struct SpectraLUT: Sendable {
    public let width: Int
    public let height: Int
    public let wavelengthCount: Int
    public let flags: UInt32
    public let sourceHash: UInt32
    public let identifier: String
    public let data: [Float]

    public static func load(from url: URL) throws -> Self {
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard bytes.count >= 32 else { throw SpectralLUTError.malformed("header too short") }
        guard String(data: bytes.prefix(4), encoding: .ascii) == "SFS2" else {
            throw SpectralLUTError.malformed("expected SFS2 magic")
        }
        func u32(_ offset: Int) -> UInt32 {
            bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let p = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                return UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
            }
        }
        let version = u32(4)
        guard version == 2 else { throw SpectralLUTError.malformed("unsupported version \(version)") }
        let width = Int(u32(8)), height = Int(u32(12)), nw = Int(u32(16))
        let flags = u32(20), hash = u32(24), idLength = Int(u32(28))
        guard width > 1, height > 1, nw > 0, idLength >= 0 else { throw SpectralLUTError.malformed("invalid dimensions") }
        let payloadOffset = 32 + idLength
        guard payloadOffset <= bytes.count else { throw SpectralLUTError.malformed("truncated identifier") }
        let identifier = String(data: bytes[32..<payloadOffset], encoding: .utf8) ?? ""
        let count = width * height * nw
        guard bytes.count == payloadOffset + count * 2 else {
            throw SpectralLUTError.malformed("payload length mismatch: got \(bytes.count - payloadOffset), expected \(count * 2)")
        }
        var values = [Float](); values.reserveCapacity(count)
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.baseAddress!.advanced(by: payloadOffset).assumingMemoryBound(to: UInt8.self)
            for i in 0..<count {
                let bits = UInt16(p[i*2]) | UInt16(p[i*2+1]) << 8
                values.append(halfBitsToFloat(bits))
            }
        }
        return .init(width: width, height: height, wavelengthCount: nw, flags: flags, sourceHash: hash, identifier: identifier, data: values)
    }

    @inline(__always) public func value(x: Int, y: Int, wavelength: Int) -> Float {
        data[((y * width + x) * wavelengthCount) + wavelength]
    }
}

private final class SpectralLUTCache: @unchecked Sendable {
    private var values: [String: TCLUT] = [:]
    private let lock = NSLock()
    func get(_ key: String) -> TCLUT? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func put(_ value: TCLUT, key: String) { lock.lock(); values[key] = value; lock.unlock() }
}

/// IEEE-754 binary16 (half-float) to binary32. `Float16(bitPattern:)` only exists on
/// arm64 in some SDKs, so decode with portable integer math instead.
@inline(__always) private func halfBitsToFloat(_ bits: UInt16) -> Float {
    let sign = bits >> 15
    let exp = Int((bits >> 10) & 0x1F)
    let mant = Int(bits & 0x3FF)
    if exp == 0x1F {
        return mant == 0 ? (sign != 0 ? -Float.infinity : Float.infinity) : Float.nan
    }
    let mantissa = exp == 0 ? mant : 1024 + mant
    let exponent = exp == 0 ? -24 : exp - 25
    return Float(Double(mantissa) * pow(2, Double(exponent)))
}

public struct PipelineResources: Sendable {
    public let pack: SpektrafilmDataPack
    public let spectra: SpectraLUT
    private let cache: SpectralLUTCache
    public init(pack: SpektrafilmDataPack, spectra: SpectraLUT) { self.pack = pack; self.spectra = spectra; self.cache = SpectralLUTCache() }

    public static func load(dataDirectory: URL) throws -> Self {
        .init(pack: try .load(from: dataDirectory.appendingPathComponent("pack.json")),
              spectra: try .load(from: dataDirectory.appendingPathComponent("spectra_lut.f32")))
    }

    public func tcLUT(for profile: FilmProfile, sensitivityOverride: [[Double]]? = nil, cacheSuffix: String = "") -> TCLUT {
        let key = "\(spectra.sourceHash):\(profile.id):\(profile.info.referenceIlluminant ?? ""):\(cacheSuffix)"
        if let cached = cache.get(key) { return cached }
        let built = SpectralService.computeTCLUT(spectra: spectra, profile: profile, illuminant: pack.illuminant(profile.info.referenceIlluminant), sensitivityOverride: sensitivityOverride)
        cache.put(built, key: key)
        return built
    }

    /// Warm profile-dependent TC LUTs across CPU cores. Film-selector thumbnails
    /// otherwise serialize this one-time setup cost for every stock.
    public func prewarmTCLUTs(for profiles: [FilmProfile]) {
        guard profiles.count > 1 else {
            if let p = profiles.first {
                let lut = tcLUT(for: p)
#if canImport(Metal)
                MetalAccelerator.shared.prewarmTCLUT(lut, cacheKey: "\(p.id):")
#endif
            }
            return
        }
        DispatchQueue.concurrentPerform(iterations: profiles.count) { i in
            let profile = profiles[i]
            let lut = tcLUT(for: profile)
#if canImport(Metal)
            MetalAccelerator.shared.prewarmTCLUT(lut, cacheKey: "\(profile.id):")
#endif
        }
    }
}
