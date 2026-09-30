#if os(macOS)
import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SpektrafilmCore
import UniformTypeIdentifiers
enum ImageCodec {
    enum CodecError: Error { case decode, bitmap, encode }
    struct ImageInfo: Sendable { let width: Int; let height: Int }

    /// 8-bit ImageIO/CGContext output has only 256 possible transfer-function
    /// inputs. A lookup table removes tens of millions of pow() calls on large JPEGs.
    private static let sRGBDecodeLUT: [Double] = (0...255).map {
        TransferFunction.sRGBDecode(Double($0) / 255.0)
    }

    private final class FullImageCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        private var image: CGImage?
        func image(for url: URL) throws -> CGImage {
            let k = url.standardizedFileURL.path
            lock.lock()
            if key == k, let image { lock.unlock(); return image }
            lock.unlock()
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { throw CodecError.decode }
            lock.lock(); key = k; image = cg; lock.unlock()
            return cg
        }
        func purge() { lock.lock(); key=nil; image=nil; lock.unlock() }
    }
    private static let fullImageCache = FullImageCache()

    struct RAWDefaults: Sendable {
        let info: ImageInfo
        let adjustments: RAWAdjustments
    }

    private final class RAWContextBox: @unchecked Sendable {
        let context = CIContext(options: [.cacheIntermediates: false])
    }
    private static let rawContext = RAWContextBox()

    /// Returns nil when Core Image does not recognize the source as a supported
    /// camera RAW. The initial white balance comes from the camera/RAW metadata.
    static func rawDefaults(url: URL) -> RAWDefaults? {
        guard let raw = CIRAWFilter(imageURL: url), let output = raw.outputImage else { return nil }
        let extent = output.extent.integral
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else { return nil }
        return RAWDefaults(
            info: ImageInfo(width: Int(extent.width), height: Int(extent.height)),
            adjustments: RAWAdjustments(
                exposureEV: Double(raw.exposure),
                temperature: Double(raw.neutralTemperature),
                tint: Double(raw.neutralTint),
                lensCorrectionEnabled: raw.isLensCorrectionEnabled
            )
        )
    }

    static func loadSourceLinearSRGB(url: URL, rawAdjustments: RAWAdjustments, isRAW: Bool) throws -> LinearRGBImage {
        if isRAW { return try loadRAWLinearSRGB(url: url, maxDimension: nil, adjustments: rawAdjustments) }
        return try loadLinearSRGB(url: url)
    }

    static func loadSourceLinearSRGBRegion(url: URL, rect: CGRect, rawAdjustments: RAWAdjustments, isRAW: Bool, outputScale: Double = 1) throws -> LinearRGBImage {
        if isRAW { return try loadRAWLinearSRGBRegion(url: url, rect: rect, adjustments: rawAdjustments, outputScale: outputScale) }
        let full = try loadLinearSRGBRegion(url: url, rect: rect)
        return abs(outputScale - 1) < 1e-9 ? full : Resample.bicubicRescale(full, factor: outputScale)
    }

    /// Develop a supported camera RAW with Core Image and return scene-linear
    /// sRGB values. `scaleFactor` is set before asking for `outputImage`, so the
    /// RAW decoder can do substantially less work for Fit/thumbnail previews.
    static func loadRAWLinearSRGB(url: URL, maxDimension: Int?, adjustments: RAWAdjustments) throws -> LinearRGBImage {
        let started = ContinuousClock.now
        guard let raw = CIRAWFilter(imageURL: url) else { throw CodecError.decode }
        raw.exposure = Float(adjustments.exposureEV)
        raw.neutralTemperature = Float(min(max(adjustments.temperature, 2000), 50000))
        raw.neutralTint = Float(min(max(adjustments.tint, -150), 150))
        raw.isLensCorrectionEnabled = adjustments.lensCorrectionEnabled

        if let maxDimension, maxDimension > 0, let full = raw.outputImage?.extent, max(full.width, full.height) > CGFloat(maxDimension) {
            let factor = Float(CGFloat(maxDimension) / max(full.width, full.height))
            raw.scaleFactor = min(max(factor, 0.001), 1)
            raw.isDraftModeEnabled = true
        } else {
            raw.scaleFactor = 1
            raw.isDraftModeEnabled = false
        }
        guard let image = raw.outputImage else { throw CodecError.decode }
        let result = try rasterizeLinearCIImage(image, bounds: image.extent.integral)
        AppLog.debug("raw", "CIRAWFilter develop \(result.width)×\(result.height): \(AppLog.formatElapsed(AppLog.msSince(started)))")
        return result
    }

    /// Render just the visible full-resolution RAW rectangle. Core Image stays
    /// lazy until CIContext renders the crop, allowing the 100%+ preview path to
    /// request only the viewport (plus the caller's halo) instead of allocating
    /// a full RGB frame. Source rectangles use the app's top-left image coords.
    static func loadRAWLinearSRGBRegion(url: URL, rect: CGRect, adjustments: RAWAdjustments, outputScale: Double = 1) throws -> LinearRGBImage {
        let started = ContinuousClock.now
        guard let raw = CIRAWFilter(imageURL: url) else { throw CodecError.decode }
        raw.exposure = Float(adjustments.exposureEV)
        raw.neutralTemperature = Float(min(max(adjustments.temperature, 2000), 50000))
        raw.neutralTint = Float(min(max(adjustments.tint, -150), 150))
        raw.isLensCorrectionEnabled = adjustments.lensCorrectionEnabled
        raw.scaleFactor = 1
        raw.isDraftModeEnabled = false
        guard let output = raw.outputImage else { throw CodecError.decode }
        let extent = output.extent.integral
        let topRect = rect.integral.intersection(CGRect(x: 0, y: 0, width: extent.width, height: extent.height))
        guard topRect.width >= 1, topRect.height >= 1 else { throw CodecError.decode }
        let ciRect = CGRect(
            x: extent.minX + topRect.minX,
            y: extent.maxY - topRect.maxY,
            width: topRect.width,
            height: topRect.height
        ).integral.intersection(extent)
        let cropped = output.cropped(to: ciRect)
        let scale = min(max(outputScale, 0.01), 1)
        let renderImage: CIImage
        let renderBounds: CGRect
        if scale < 0.999_999 {
            // Scale the lazy RAW crop before rasterization. Core Image / CIRAWFilter can
            // therefore produce only the draft pixels instead of materializing a 704²
            // tile and then running the Swift bicubic scaler over it.
            let normalized = cropped.transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            renderImage = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            renderBounds = renderImage.extent.integral
        } else {
            renderImage = cropped
            renderBounds = ciRect
        }
        let result = try rasterizeLinearCIImage(renderImage, bounds: renderBounds)
        AppLog.debug("raw", "CIRAWFilter viewport \(result.width)×\(result.height) scale=\(String(format: "%.2f", scale)): \(AppLog.formatElapsed(AppLog.msSince(started)))")
        return result
    }

    private static func rasterizeLinearCIImage(_ image: CIImage, bounds: CGRect) throws -> LinearRGBImage {
        let b = bounds.integral
        let w = Int(b.width), h = Int(b.height)
        guard w > 0, h > 0 else { throw CodecError.bitmap }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        guard let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { throw CodecError.bitmap }
        rgba.withUnsafeMutableBytes { ptr in
            rawContext.context.render(
                image,
                toBitmap: ptr.baseAddress!,
                rowBytes: w * 4 * MemoryLayout<Float>.size,
                bounds: b,
                format: .RGBAf,
                colorSpace: linearSRGB
            )
        }
        var pixels = [Double](repeating: 0, count: w * h * 3)
        pixels.withUnsafeMutableBufferPointer { dst in
            rgba.withUnsafeBufferPointer { src in
                for i in 0..<(w * h) {
                    let si = i * 4, di = i * 3
                    dst[di] = Double(src[si])
                    dst[di + 1] = Double(src[si + 1])
                    dst[di + 2] = Double(src[si + 2])
                }
            }
        }
        return LinearRGBImage(width: w, height: h, pixels: pixels)
    }

    static func inspect(url: URL) throws -> ImageInfo {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CodecError.decode }
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? NSNumber,
           let h = props[kCGImagePropertyPixelHeight] as? NSNumber {
            return ImageInfo(width: w.intValue, height: h.intValue)
        }
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw CodecError.decode }
        return ImageInfo(width: cg.width, height: cg.height)
    }

    static func loadLinearSRGBThumbnail(url: URL, maxDimension: Int) throws -> LinearRGBImage {
        let decodeStart = ContinuousClock.now
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CodecError.decode }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: max(maxDimension, 1),
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            let result = try rasterizeLinearSRGB(thumb)
            AppLog.debug("codec", "ImageIO thumbnail decode+raster \(result.width)×\(result.height): \(AppLog.formatElapsed(AppLog.msSince(decodeStart)))")
            return result
        }
        // Some high-bit-depth TIFF representations reject ImageIO's thumbnail
        // block format. Draw the lazy full CGImage directly into a small context;
        // importantly, never construct a full-size [Double] just to make a proxy.
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw CodecError.decode }
        let result = try rasterizeLinearSRGB(cg, maxDimension: maxDimension)
        AppLog.debug("codec", "CG fallback proxy decode+raster \(result.width)×\(result.height): \(AppLog.formatElapsed(AppLog.msSince(decodeStart)))")
        return result
    }

    static func loadLinearSRGB(url: URL) throws -> LinearRGBImage {
        let started = ContinuousClock.now
        let cg = try fullImageCache.image(for: url)
        let result = try rasterizeLinearSRGB(cg)
        AppLog.debug("codec", "Full image raster+linearize \(result.width)×\(result.height): \(AppLog.formatElapsed(AppLog.msSince(started)))")
        return result
    }

    static func loadLinearSRGBRegion(url: URL, rect: CGRect) throws -> LinearRGBImage {
        let cg = try fullImageCache.image(for: url)
        let imageBounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let r = rect.integral.intersection(imageBounds)
        guard r.width >= 1, r.height >= 1, let crop = cg.cropping(to: r) else { throw CodecError.decode }
        return try rasterizeLinearSRGB(crop)
    }

    private static func rasterizeLinearSRGB(_ cg: CGImage, maxDimension: Int? = nil) throws -> LinearRGBImage {
        let sw = cg.width, sh = cg.height
        let scale: Double
        if let maxDimension, max(sw, sh) > maxDimension { scale = Double(maxDimension) / Double(max(sw, sh)) }
        else { scale = 1 }
        let w = max(1, Int((Double(sw) * scale).rounded()))
        let h = max(1, Int((Double(sh) * scale).rounded()))
        let bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: h * bpr)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CodecError.bitmap }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var pixels = [Double](repeating: 0, count: w * h * 3)
        pixels.withUnsafeMutableBufferPointer { dst in
            bytes.withUnsafeBufferPointer { src in
                for i in 0..<(w*h) {
                    let si=i*4, di=i*3
                    dst[di] = sRGBDecodeLUT[Int(src[si])]
                    dst[di+1] = sRGBDecodeLUT[Int(src[si+1])]
                    dst[di+2] = sRGBDecodeLUT[Int(src[si+2])]
                }
            }
        }
        return LinearRGBImage(width: w, height: h, pixels: pixels)
    }

    static func makeNSImage(_ image: LinearRGBImage, encodeSRGB: Bool) -> NSImage? {
        let w=image.width, h=image.height, bpr=w*4
        var bytes=[UInt8](repeating:0,count:h*bpr)
        for i in 0..<(w*h) {
            for c in 0..<3 {
                var v=image.pixels[i*3+c]
                if encodeSRGB { v=TransferFunction.sRGBEncode(v) }
                bytes[i*4+c]=UInt8((min(max(v,0),1)*255).rounded())
            }
            bytes[i*4+3]=255
        }
        guard let provider=CGDataProvider(data:Data(bytes) as CFData),let cs=CGColorSpace(name:CGColorSpace.sRGB),
              let cg=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:bpr,space:cs,
                             bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,
                             decode:nil,shouldInterpolate:true,intent:.defaultIntent) else{return nil}
        return NSImage(cgImage:cg,size:NSSize(width:w,height:h))
    }

    static func save(
        _ image: LinearRGBImage,
        to url: URL,
        settings: ExportSettings,
        outputColorSpace: String,
        pixelsAreTransferEncoded: Bool,
        metadataSourceURL: URL?
    ) throws {
        let bitDepth = settings.effectiveBitDepth
        let cgImage = try makeExportCGImage(
            image,
            bitDepth: bitDepth,
            outputColorSpace: outputColorSpace,
            pixelsAreTransferEncoded: pixelsAreTransferEncoded
        )

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            settings.format.contentType.identifier as CFString,
            1,
            nil
        ) else { throw CodecError.encode }

        var properties = exportMetadata(from: metadataSourceURL, width: image.width, height: image.height)

        switch settings.format {
        case .jpeg:
            properties[kCGImageDestinationLossyCompressionQuality] = settings.jpegQuality as NSNumber
        case .tiff:
            var tiff = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = settings.tiffCompression.imageIOValue as NSNumber
            properties[kCGImagePropertyTIFFDictionary] = tiff
        case .png:
            var png = (properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]) ?? [:]
            png[kCGImagePropertyPNGInterlaceType] = (settings.pngInterlaced ? 1 : 0) as NSNumber
            properties[kCGImagePropertyPNGDictionary] = png
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CodecError.encode }
    }

    private static func makeExportCGImage(
        _ image: LinearRGBImage,
        bitDepth: ExportBitDepth,
        outputColorSpace: String,
        pixelsAreTransferEncoded: Bool
    ) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw CodecError.bitmap }
        guard let colorSpace = exportColorSpace(named: outputColorSpace) else { throw CodecError.bitmap }

        @inline(__always)
        func outputValue(_ x: Double) -> Double {
            let encoded = pixelsAreTransferEncoded ? x : TransferFunction.encode(forColorSpace: outputColorSpace, x)
            return min(max(encoded, 0), 1)
        }

        switch bitDepth {
        case .eight:
            let bytesPerRow = width * 3
            var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
            for i in 0..<(width * height) {
                let source = i * 3
                bytes[source] = UInt8((outputValue(image.pixels[source]) * 255).rounded())
                bytes[source + 1] = UInt8((outputValue(image.pixels[source + 1]) * 255).rounded())
                bytes[source + 2] = UInt8((outputValue(image.pixels[source + 2]) * 255).rounded())
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cg = CGImage(
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 24,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) else { throw CodecError.bitmap }
            return cg

        case .sixteen:
            // Store 16-bit components explicitly in big-endian order. The image
            // stays at full pipeline precision until this final quantization.
            let bytesPerRow = width * 3 * 2
            var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
            for i in 0..<(width * height) {
                let source = i * 3
                let destination = i * 6
                for channel in 0..<3 {
                    let sample = UInt16((outputValue(image.pixels[source + channel]) * 65535).rounded())
                    bytes[destination + channel * 2] = UInt8(sample >> 8)
                    bytes[destination + channel * 2 + 1] = UInt8(sample & 0x00ff)
                }
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cg = CGImage(
                    width: width,
                    height: height,
                    bitsPerComponent: 16,
                    bitsPerPixel: 48,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) else { throw CodecError.bitmap }
            return cg
        }
    }

    private static func exportColorSpace(named name: String) -> CGColorSpace? {
        switch name.lowercased() {
        case "display p3", "p3":
            return CGColorSpace(name: CGColorSpace.displayP3)
        case "adobe rgb (1998)", "adobe rgb", "adobergb":
            return CGColorSpace(name: CGColorSpace.adobeRGB1998)
        case "prophoto rgb", "prophoto":
            return CGColorSpace(name: CGColorSpace.rommrgb)
        case "rec.2020", "itu-r bt.2020", "bt.2020", "bt2020":
            return CGColorSpace(name: CGColorSpace.itur_2020)
        case "acescg":
            return CGColorSpace(name: CGColorSpace.acescgLinear)
        default:
            return CGColorSpace(name: CGColorSpace.sRGB)
        }
    }

    /// Copy descriptive/camera metadata from the source while leaving pixel
    /// encoding facts to the new CGImage. This preserves EXIF camera/lens/time,
    /// EXIF auxiliary, GPS, IPTC and TIFF descriptive tags when the destination
    /// encoder supports them. EXIF pixel dimensions are updated for crop/upscale.
    private static func exportMetadata(from sourceURL: URL?, width: Int, height: Int) -> [CFString: Any] {
        guard let sourceURL,
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }

        var output: [CFString: Any] = [:]
        let passthroughKeys: [CFString] = [
            kCGImagePropertyExifAuxDictionary,
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary,
            kCGImagePropertyTIFFDictionary
        ]
        for key in passthroughKeys {
            if let value = sourceProperties[key] { output[key] = value }
        }

        if var exif = sourceProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width as NSNumber
            exif[kCGImagePropertyExifPixelYDimension] = height as NSNumber
            output[kCGImagePropertyExifDictionary] = exif
        }

        return output
    }
}
#endif
