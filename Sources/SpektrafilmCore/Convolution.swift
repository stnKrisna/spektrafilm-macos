import Foundation

public enum Convolution {
    public static func gaussianBlur(_ image: LinearRGBImage, sigma: Double, useGPU: Bool = false) -> LinearRGBImage {
        gaussianBlur(image, sigmas: [sigma, sigma, sigma], useGPU: useGPU)
    }

    /// Per-channel separable Gaussian using scipy.ndimage-compatible reflect boundaries.
    public static func gaussianBlur(_ image: LinearRGBImage, sigmas: [Double], useGPU: Bool = false) -> LinearRGBImage {
        if useGPU, let accelerated = MetalAccelerator.shared.gaussianBlur(image, sigmas: sigmas) { return accelerated }
        let s = (0..<3).map { $0 < sigmas.count ? sigmas[$0] : (sigmas.last ?? 0) }
        guard s.contains(where: { $0 > 0.05 }) else { return image }
        var temp = image
        var out = image
        for c in 0..<3 {
            let sigma = s[c]
            guard sigma > 0.05 else { continue }
            let radius = max(Int(3.0 * sigma + 0.5), 1)
            let kernel = gaussianKernel(sigma: sigma, radius: radius)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    var sum = 0.0
                    for k in -radius...radius {
                        sum += image[reflect(x + k, image.width), y, c] * kernel[k + radius]
                    }
                    temp[x, y, c] = sum
                }
            }
            for y in 0..<image.height {
                for x in 0..<image.width {
                    var sum = 0.0
                    for k in -radius...radius {
                        sum += temp[x, reflect(y + k, image.height), c] * kernel[k + radius]
                    }
                    out[x, y, c] = sum
                }
            }
        }
        return out
    }

    /// Three-Gaussian surrogate used by Python's fast_exponential_filter.
    public static func exponentialBlur(_ image: LinearRGBImage, decay: [Double], useGPU: Bool = false) -> LinearRGBImage {
        if useGPU, let accelerated = MetalAccelerator.shared.exponentialBlur(image, decay: decay) { return accelerated }
        let fit: [(Double, Double)] = [(0.1633, 0.5360), (0.6496, 1.5236), (0.1870, 2.7684)]
        var out = LinearRGBImage(width: image.width, height: image.height)
        for (amplitude, ratio) in fit {
            let sigmas = (0..<3).map { c in
                max((c < decay.count ? decay[c] : decay.last ?? 0) * ratio, 1e-6)
            }
            let blurred = gaussianBlur(image, sigmas: sigmas, useGPU: useGPU)
            for i in out.pixels.indices { out.pixels[i] += amplitude * blurred.pixels[i] }
        }
        return out
    }

    public static func unsharpMask(_ image: LinearRGBImage, sigma: Double, amount: Double, useGPU: Bool = false) -> LinearRGBImage {
        guard amount != 0 && sigma > 0 else { return image }
        let blur = gaussianBlur(image, sigma: sigma, useGPU: useGPU)
        var out = image
        for i in out.pixels.indices { out.pixels[i] = image.pixels[i] + amount * (image.pixels[i] - blur.pixels[i]) }
        return out
    }

    private static func reflect(_ i: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        let period = 2 * n
        var j = i % period
        if j < 0 { j += period }
        if j >= n { j = period - 1 - j }
        return j
    }

    private static func gaussianKernel(sigma: Double, radius: Int) -> [Double] {
        var kernel = [Double](repeating: 0, count: radius * 2 + 1)
        var sum = 0.0
        for i in -radius...radius {
            let value = exp(-0.5 * Double(i * i) / (sigma * sigma))
            kernel[i + radius] = value
            sum += value
        }
        return kernel.map { $0 / sum }
    }
}
