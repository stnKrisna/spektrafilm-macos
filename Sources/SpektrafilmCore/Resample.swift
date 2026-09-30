import Foundation

/// Area/bilinear resampling used to keep low-frequency, full-resolution work
/// (halation bloom, display previews) on a bounded work image. Results are not
/// bit-parity fixtures; they are deterministic CPU approximations.
public enum Resample {
    /// Longest side of the working copy for halation. Halation is a physically
    /// low-frequency bloom (tens of µm ⇔ ~10–35 px kernels), so blurring beyond
    /// 2K wastes compute; ~2K is visually indistinguishable on full-res output.
    public static let halationWorkDimension = 2048

    /// Scale factor (>= 1) so the image's longest side maps to `maxDimension`.
    /// Returns 1 when the image is already at or below the limit.
    public static func scaleFactor(for image: LinearRGBImage, maxDimension: Int) -> Double {
        let maxDim = max(image.width, image.height)
        guard maxDim > maxDimension else { return 1 }
        return Double(maxDim) / Double(maxDimension)
    }

    /// Downscale to fit the longest side within `maxDimension`; returns the input
    /// unchanged when already small enough.
    public static func resize(_ image: LinearRGBImage, maxDimension: Int) -> LinearRGBImage {
        let f = scaleFactor(for: image, maxDimension: maxDimension)
        guard f > 1 else { return image }
        return boxAverageDownscale(image, factor: f)
    }

    /// Area-average downsample. Each destination pixel integrates its source
    /// block, so constant regions reproduce without low-pass error.
    public static func boxAverageDownscale(_ image: LinearRGBImage, factor: Double) -> LinearRGBImage {
        guard factor > 1, image.width > 1, image.height > 1 else { return image }
        let sw = image.width, sh = image.height
        let dw = max(Int((Double(sw) / factor).rounded()), 1)
        let dh = max(Int((Double(sh) / factor).rounded()), 1)
        var out = LinearRGBImage(width: dw, height: dh)
        for dy in 0..<dh {
            let yb = Double(dy) * factor
            let yStart = Int(yb.rounded(.down))
            let yEnd = min(yStart + max(Int((yb + factor).rounded(.up)) - yStart, 1), sh)
            if yEnd <= yStart { continue }
            for dx in 0..<dw {
                let xb = Double(dx) * factor
                let xStart = Int(xb.rounded(.down))
                let xEnd = min(xStart + max(Int((xb + factor).rounded(.up)) - xStart, 1), sw)
                if xEnd <= xStart { continue }
                var r = 0.0, g = 0.0, b = 0.0
                for sy in yStart..<yEnd {
                    for sx in xStart..<xEnd {
                        let i = image.index(x: sx, y: sy, c: 0)
                        r += image.pixels[i]
                        g += image.pixels[i + 1]
                        b += image.pixels[i + 2]
                    }
                }
                let n = (xEnd - xStart) * (yEnd - yStart)
                guard n > 0 else { continue }
                let inv = 1.0 / Double(n)
                let oi = out.index(x: dx, y: dy, c: 0)
                out.pixels[oi] = r * inv
                out.pixels[oi + 1] = g * inv
                out.pixels[oi + 2] = b * inv
            }
        }
        return out
    }

    /// Build the halation highlight mask (`min(max(luma-1,0)/(knee-1),1) × pixel`)
    /// directly onto the working buffer, averaging blocks for the downscale.
    static func downscaleHighlights(_ exposure: LinearRGBImage, targetWidth: Int, targetHeight: Int, knee: Double) -> LinearRGBImage {
        let sw = exposure.width, sh = exposure.height
        var out = LinearRGBImage(width: targetWidth, height: targetHeight)
        let fx = Double(sw) / max(Double(targetWidth), 1)
        let fy = Double(sh) / max(Double(targetHeight), 1)
        let halfKnee = (knee - 1) > 1e-9 ? knee - 1 : 1e-9
        if targetWidth == sw && targetHeight == sh {
            for y in 0..<sh {
                for x in 0..<sw {
                    let i = exposure.index(x: x, y: y, c: 0)
                    let r = exposure.pixels[i], g = exposure.pixels[i + 1], b = exposure.pixels[i + 2]
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let mask = min(max(0, luma - 1) / halfKnee, 1)
                    let oi = out.index(x: x, y: y, c: 0)
                    out.pixels[oi] = mask * r
                    out.pixels[oi + 1] = mask * g
                    out.pixels[oi + 2] = mask * b
                }
            }
            return out
        }
        for dy in 0..<targetHeight {
            let yb = Double(dy) * fy
            let yStart = Int(yb.rounded(.down))
            let yEnd = min(yStart + max(Int((yb + fy).rounded(.up)) - yStart, 1), sh)
            if yEnd <= yStart { continue }
            for dx in 0..<targetWidth {
                let xb = Double(dx) * fx
                let xStart = Int(xb.rounded(.down))
                let xEnd = min(xStart + max(Int((xb + fx).rounded(.up)) - xStart, 1), sw)
                if xEnd <= xStart { continue }
                var r = 0.0, g = 0.0, b = 0.0
                for sy in yStart..<yEnd {
                    for sx in xStart..<xEnd {
                        let i = exposure.index(x: sx, y: sy, c: 0)
                        let vr = exposure.pixels[i], vg = exposure.pixels[i + 1], vb = exposure.pixels[i + 2]
                        let luma = 0.2126 * vr + 0.7152 * vg + 0.0722 * vb
                        let mask = min(max(0, luma - 1) / halfKnee, 1)
                        r += mask * vr
                        g += mask * vg
                        b += mask * vb
                    }
                }
                let n = (xEnd - xStart) * (yEnd - yStart)
                guard n > 0 else { continue }
                let inv = 1.0 / Double(n)
                let oi = out.index(x: dx, y: dy, c: 0)
                out.pixels[oi] = r * inv
                out.pixels[oi + 1] = g * inv
                out.pixels[oi + 2] = b * inv
            }
        }
        return out
    }

    /// Bilinear upscale back to the full-resolution grid. Returns the input
    /// unchanged when target dimensions already match.
    public static func bilinearUpscale(_ image: LinearRGBImage, toWidth: Int, toHeight: Int) -> LinearRGBImage {
        guard toWidth != image.width || toHeight != image.height else { return image }
        let sw = image.width, sh = image.height
        guard sw > 0, sh > 0 else { return image }
        var out = LinearRGBImage(width: toWidth, height: toHeight)
        for y in 0..<toHeight {
            let sy = max(min((Double(y) + 0.5) / Double(toHeight) * Double(sh) - 0.5, Double(sh) - 1), 0)
            let yi = Int(sy.rounded(.down))
            let yi1 = min(yi + 1, sh - 1)
            let ty = sy - Double(yi)
            for x in 0..<toWidth {
                let sx = max(min((Double(x) + 0.5) / Double(toWidth) * Double(sw) - 0.5, Double(sw) - 1), 0)
                let xi = Int(sx.rounded(.down))
                let xi1 = min(xi + 1, sw - 1)
                let tx = sx - Double(xi)
                let i00 = image.index(x: xi, y: yi, c: 0)
                let i10 = image.index(x: xi1, y: yi, c: 0)
                let i01 = image.index(x: xi, y: yi1, c: 0)
                let i11 = image.index(x: xi1, y: yi1, c: 0)
                let oi = out.index(x: x, y: y, c: 0)
                for c in 0..<3 {
                    let top = image.pixels[i00 + c] * (1 - tx) + image.pixels[i10 + c] * tx
                    let bottom = image.pixels[i01 + c] * (1 - tx) + image.pixels[i11 + c] * tx
                    out.pixels[oi + c] = top * (1 - ty) + bottom * ty
                }
            }
        }
        return out
    }
}
extension Resample {
    /// Python crop_image parity: size is expressed as a fraction of the original long side.
    public static func cropNormalized(_ image: LinearRGBImage, center: [Double], size: [Double]) -> LinearRGBImage {
        guard image.width > 0, image.height > 0 else { return image }
        let cx = center.indices.contains(0) ? center[0] : 0.5
        let cy = center.indices.contains(1) ? center[1] : 0.5
        let sx = max(size.indices.contains(0) ? size[0] : 0.1, 1.0 / Double(max(image.width, image.height)))
        let sy = max(size.indices.contains(1) ? size[1] : 0.1, 1.0 / Double(max(image.width, image.height)))
        let long = Double(max(image.width, image.height))
        let w = min(max(Int((long * sx).rounded()), 1), image.width)
        let h = min(max(Int((long * sy).rounded()), 1), image.height)
        var x0 = Int((Double(image.width) * cx - Double(w) / 2).rounded())
        var y0 = Int((Double(image.height) * cy - Double(h) / 2).rounded())
        x0 = min(max(x0, 0), max(image.width - w, 0))
        y0 = min(max(y0, 0), max(image.height - h, 0))
        var out = LinearRGBImage(width: w, height: h)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 { out[x,y,c] = image[x+x0,y+y0,c] } } }
        return out
    }

    /// Cubic rescale used by Python's skimage.transform.rescale for the user-facing upscale control.
    /// Uses Catmull-Rom bicubic interpolation with reflect boundary handling.
    public static func bicubicRescale(_ image: LinearRGBImage, factor: Double) -> LinearRGBImage {
        guard factor > 0, abs(factor - 1) > 1e-12 else { return image }
        let dw = max(Int((Double(image.width) * factor).rounded()), 1)
        let dh = max(Int((Double(image.height) * factor).rounded()), 1)
        var out = LinearRGBImage(width: dw, height: dh)
        func reflect(_ i: Int, _ n: Int) -> Int {
            guard n > 1 else { return 0 }
            let period = 2 * n
            var j = i % period; if j < 0 { j += period }
            return j >= n ? period - 1 - j : j
        }
        func weight(_ x: Double) -> Double {
            let a = -0.5, t = abs(x)
            if t < 1 { return (a + 2)*t*t*t - (a + 3)*t*t + 1 }
            if t < 2 { return a*t*t*t - 5*a*t*t + 8*a*t - 4*a }
            return 0
        }
        for y in 0..<dh {
            let sy = (Double(y)+0.5)/factor - 0.5, yi = Int(floor(sy)), fy = sy-Double(yi)
            for x in 0..<dw {
                let sx = (Double(x)+0.5)/factor - 0.5, xi = Int(floor(sx)), fx = sx-Double(xi)
                for c in 0..<3 {
                    var sum = 0.0, ws = 0.0
                    for ky in -1...2 { for kx in -1...2 {
                        let w = weight(Double(kx)-fx) * weight(Double(ky)-fy)
                        sum += image[reflect(xi+kx,image.width), reflect(yi+ky,image.height), c] * w
                        ws += w
                    }}
                    out[x,y,c] = ws == 0 ? 0 : sum/ws
                }
            }
        }
        return out
    }
}
