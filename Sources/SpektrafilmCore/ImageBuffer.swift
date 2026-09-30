import Foundation

/// Interleaved, scene-linear RGB image using Double precision.
/// The Rust reference keeps the high-quality CPU path in f64; this type does the same.
public struct LinearRGBImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [Double]

    public init(width: Int, height: Int, pixels: [Double]) {
        precondition(width > 0 && height > 0)
        precondition(pixels.count == width * height * 3)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, repeating value: Double = 0) {
        self.init(width: width, height: height, pixels: Array(repeating: value, count: width * height * 3))
    }

    @inline(__always) public func index(x: Int, y: Int, c: Int) -> Int {
        ((y * width) + x) * 3 + c
    }

    public subscript(x: Int, y: Int, c: Int) -> Double {
        get { pixels[index(x: x, y: y, c: c)] }
        set { pixels[index(x: x, y: y, c: c)] = newValue }
    }

    public mutating func mapInPlace(_ body: (Double) -> Double) {
        for i in pixels.indices { pixels[i] = body(pixels[i]) }
    }

    public func mapped(_ body: (Double) -> Double) -> Self {
        var copy = self
        copy.mapInPlace(body)
        return copy
    }

    public func allFinite() -> Bool { pixels.allSatisfy(\.isFinite) }
}

public enum TransferFunction {
    @inline(__always) public static func sRGBDecode(_ x: Double) -> Double {
        let v = max(0, x)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    @inline(__always) public static func sRGBEncode(_ x: Double) -> Double {
        let v = max(0, x)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    /// ProPhoto RGB opto-electronic transfer function (IEC 61966-2-2 / ROMM-RGB).
    @inline(__always) public static func proPhotoEncode(_ x: Double) -> Double {
        let v = max(0, x)
        return v <= 1.0 / 512.0 ? v * 16.0 : pow(v, 1.0 / 1.8)
    }

    /// Encode scene-linear values with the transfer curve of the named output color
    /// space, mirroring upstream `colour.RGB_to_RGB(..., apply_cctf_encoding=True)`.
    public static func encode(forColorSpace name: String, _ x: Double) -> Double {
        switch name.lowercased() {
        case "prophoto rgb", "prophoto":
            return proPhotoEncode(x)
        case "adobe rgb (1998)", "adobe rgb", "adobergb", "display p3", "p3", "itu-r bt.2020", "rec.2020", "bt.2020", "bt2020", "acescg":
            return x
        default:
            return sRGBEncode(x)
        }
    }
}
