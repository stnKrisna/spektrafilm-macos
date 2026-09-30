import Foundation

public struct FilmProfile: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { info.stock ?? info.name ?? "unnamed" }
    public let metadata: ProfileMetadata
    public let info: ProfileInfo
    public let data: ProfileData

    public static func load(from url: URL) throws -> FilmProfile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FilmProfile.self, from: data)
    }
}

public struct ProfileMetadata: Decodable, Sendable, Equatable {
    public let version: String?
    public let copyright: String?
    public let created: String?
    public let license: String?
    public let citation: String?
    public let datasource: String?
}

public struct ProfileInfo: Decodable, Sendable, Equatable {
    public let stock: String?
    public let name: String?
    public let type: String?
    public let support: String?
    public let stage: String?
    public let use: String?
    public let antihalation: String?
    public let targetPrint: String?
    public let channelModel: String?
    public let densitometer: String?
    public let logSensitivityDensityOverMin: Double?
    public let referenceIlluminant: String?
    public let viewingIlluminant: String?

    enum CodingKeys: String, CodingKey {
        case stock, name, type, support, stage, use, antihalation, densitometer
        case targetPrint = "target_print"
        case channelModel = "channel_model"
        case logSensitivityDensityOverMin = "log_sensitivity_density_over_min"
        case referenceIlluminant = "reference_illuminant"
        case viewingIlluminant = "viewing_illuminant"
    }
}

public struct DensityCurvesModel: Decodable, Sendable, Equatable {
    public let type: String?
    public let centers: [[Double]]
    public let amplitudes: [[Double]]
    public let sigmas: [[Double]]

    enum CodingKeys: String, CodingKey { case type = "model_type", centers, amplitudes, sigmas }
}

public struct ProfileData: Decodable, Sendable, Equatable {
    public let wavelengths: [Double]
    public let logSensitivity: [[Double]]
    public let rawLogSensitivity: [[Double?]]
    public let hanatosAdaptationWindowParameters: [Double]
    public let hanatosAdaptationSurfaceParameters: [[Double]]
    public let channelDensity: [[Double?]]
    public let baseDensityRows: [[Double?]]
    public let midscaleNeutralDensity: [Double?]
    public let logExposure: [Double]
    public let densityCurves: [[Double]]
    public let densityCurvesLayers: [[[Double]]]
    public let densityCurvesModel: DensityCurvesModel?
    public let developmentTime: [Double]

    enum CodingKeys: String, CodingKey {
        case wavelengths
        case logSensitivity = "log_sensitivity"
        case hanatosAdaptationWindowParameters = "hanatos2025_adaptation_window_params"
        case hanatosAdaptationSurfaceParameters = "hanatos2025_adaptation_surface_params"
        case channelDensity = "channel_density"
        case baseDensityRows = "base_density"
        case midscaleNeutralDensity = "midscale_neutral_density"
        case logExposure = "log_exposure"
        case densityCurves = "density_curves"
        case densityCurvesLayers = "density_curves_layers"
        case densityCurvesModel = "density_curves_model"
        case developmentTime = "development_time"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wavelengths = (try? c.decode([Double].self, forKey: .wavelengths)) ?? []
        rawLogSensitivity = Self.decodeNullableMatrix(c, .logSensitivity)
        logSensitivity = rawLogSensitivity.map { $0.map { $0 ?? 0 } }
        hanatosAdaptationWindowParameters = Self.decodeFiniteVector(c, .hanatosAdaptationWindowParameters)
        hanatosAdaptationSurfaceParameters = Self.decodeFiniteMatrix(c, .hanatosAdaptationSurfaceParameters)
        channelDensity = Self.decodeNullableMatrix(c, .channelDensity)
        baseDensityRows = Self.decodeFlexibleNullableMatrix(c, .baseDensityRows)
        midscaleNeutralDensity = Self.decodeNullableVector(c, .midscaleNeutralDensity)
        logExposure = Self.decodeFiniteVector(c, .logExposure)
        densityCurves = Self.decodeFiniteMatrix(c, .densityCurves)
        densityCurvesLayers = Self.decodeFiniteTensor(c, .densityCurvesLayers)
        densityCurvesModel = try? c.decodeIfPresent(DensityCurvesModel.self, forKey: .densityCurvesModel)
        developmentTime = Self.decodeFiniteVector(c, .developmentTime)
    }

    private static func decodeFiniteVector(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [Double] {
        guard let v = try? c.decode([Double?].self, forKey: key) else { return [] }
        return v.map { $0 ?? 0 }
    }
    private static func decodeNullableVector(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [Double?] {
        (try? c.decode([Double?].self, forKey: key)) ?? []
    }
    private static func decodeFiniteMatrix(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [[Double]] {
        guard let m = try? c.decode([[Double?]].self, forKey: key) else { return [] }
        return m.map { $0.map { $0 ?? 0 } }
    }
    private static func decodeNullableMatrix(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [[Double?]] {
        (try? c.decode([[Double?]].self, forKey: key)) ?? []
    }
    private static func decodeFlexibleNullableMatrix(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [[Double?]] {
        if let m = try? c.decode([[Double?]].self, forKey: key) { return m }
        if let v = try? c.decode([Double?].self, forKey: key) { return v.map { [$0] } }
        return []
    }
    private static func decodeFiniteTensor(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [[[Double]]] {
        guard let t = try? c.decode([[[Double?]]].self, forKey: key) else { return [] }
        return t.map { $0.map { $0.map { $0 ?? 0 } } }
    }
}

public enum ProfileLibrary {
    public static func loadDirectory(_ url: URL) throws -> [FilmProfile] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        AppLog.debug("profile", "Found \(urls.count) JSON file(s) in \(url.path)")
        var profiles: [FilmProfile] = []
        for file in urls {
            do {
                profiles.append(try FilmProfile.load(from: file))
            } catch {
                AppLog.warning("profile", "Skipping '\(file.lastPathComponent)': \(error)")
            }
        }
        AppLog.info("profile", "Loaded \(profiles.count)/\(urls.count) valid profile(s) from \(url.path)")
        return profiles
    }
}
