import Foundation

#if canImport(Metal)
import Metal

/// Float32 Metal acceleration for the interactive preview path.
/// The Double CPU implementation remains the parity/export reference.
public final class MetalAccelerator: @unchecked Sendable {
    public static let shared = MetalAccelerator()

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    var pipelines: [String: MTLComputePipelineState] = [:]
    private var immutableBuffers: [String: MTLBuffer] = [:]
    private var immutableBufferLRU: [String] = []
    private let immutableBufferLimit = 128
    private let lock = NSLock()

    public enum WorkPriority: Int, Sendable { case background = 0, normal = 1, interactive = 2 }
    private let gpuGate = NSCondition()
    private var gpuBusy = false
    private var waitingInteractive = 0
    private static let workPriorityThreadKey = "SpektrafilmCore.MetalAccelerator.WorkPriority"

    var currentWorkPriority: WorkPriority {
        if let raw = Thread.current.threadDictionary[Self.workPriorityThreadKey] as? Int, let value = WorkPriority(rawValue: raw) { return value }
        return .normal
    }

    @discardableResult
    public func withWorkPriority<T>(_ priority: WorkPriority, _ body: () throws -> T) rethrows -> T {
        let dict = Thread.current.threadDictionary
        let previous = dict[Self.workPriorityThreadKey]
        dict[Self.workPriorityThreadKey] = priority.rawValue
        defer {
            if let previous { dict[Self.workPriorityThreadKey] = previous } else { dict.removeObject(forKey: Self.workPriorityThreadKey) }
        }
        return try body()
    }

    func acquireGPUSlot() {
        let priority = currentWorkPriority
        gpuGate.lock()
        if priority == .interactive { waitingInteractive += 1 }
        while gpuBusy || (priority != .interactive && waitingInteractive > 0) { gpuGate.wait() }
        if priority == .interactive { waitingInteractive -= 1 }
        gpuBusy = true
        gpuGate.unlock()
    }

    func releaseGPUSlot() {
        gpuGate.lock(); gpuBusy = false; gpuGate.broadcast(); gpuGate.unlock()
    }

    public var isAvailable: Bool { device != nil && queue != nil && !pipelines.isEmpty }

    /// A resident preview render records every compute pass into one command buffer.
    /// The batch is thread-scoped because the synchronous pipeline may run concurrently
    /// for independent thumbnails/tiles on different worker threads.
    final class ResidentBatch {
        let commandBuffer: MTLCommandBuffer
        init(_ commandBuffer: MTLCommandBuffer) { self.commandBuffer = commandBuffer }
    }
    static let residentBatchThreadKey = "SpektrafilmCore.MetalAccelerator.ResidentBatch"

    var currentResidentBatch: ResidentBatch? {
        Thread.current.threadDictionary[Self.residentBatchThreadKey] as? ResidentBatch
    }

    /// Encode a complete synchronous resident render into one Metal command buffer.
    /// Nested callers reuse the outer batch.
    public func withResidentBatch<T>(_ body: () -> T?) -> T? {
        if currentResidentBatch != nil { return body() }
        acquireGPUSlot()
        defer { releaseGPUSlot() }
        guard let queue, let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let batch = ResidentBatch(commandBuffer)
        Thread.current.threadDictionary[Self.residentBatchThreadKey] = batch
        let value = body()
        Thread.current.threadDictionary.removeObject(forKey: Self.residentBatchThreadKey)
        guard value != nil else { return nil }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed ? value : nil
    }

    /// Kernel functions required from the Metal library, compiled from
    /// `Shaders/SpektrafilmKernels.metal` (Xcode: build time) or the embedded
    /// source string (SwiftPM: runtime).
    private static let kernelNames = ["rgb_to_film_raw", "print_exposure", "density_to_rgb", "gaussian_h", "gaussian_v", "grain_simple", "grain_layers", "develop_linear", "dir_inhibitor", "dir_redevelop", "accumulate_weighted", "log10_transform", "blend_buffers", "add_scaled", "gamut_compress_cam16", "scanner_finish", "unsharp_combine", "density_to_rgb_cam16", "scale_rgb", "boost_highlights", "reduce_max_rgb", "linear_combine", "combine_channels"]

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            self.device = nil; self.queue = nil; return
        }
        self.device = device; self.queue = queue

        // Xcode compiles SpektrafilmKernels.metal into the app bundle's default
        // Metal library at build time. Prefer it when every kernel is present.
        var library = device.makeDefaultLibrary().flatMap { lib in
            Self.kernelNames.allSatisfy { lib.makeFunction(name: $0) != nil } ? lib : nil
        }
        if library != nil {
            AppLog.info("metal", "Using build-time compiled default Metal library")
        }
        #if SWIFT_PACKAGE
        if library == nil {
            // SwiftPM cannot compile .metal files in library targets; the
            // MetalKernelSourcePlugin embeds the canonical MSL as a string
            // that is compiled here at runtime.
            do {
                library = try device.makeLibrary(source: Self.source, options: nil)
            } catch {
                AppLog.error("metal", "Metal kernel compilation failed: \(error)")
            }
        }
        #endif

        guard let library else {
            AppLog.error("metal", "Metal kernel library unavailable; Metal preview disabled")
            return
        }
        do {
            for name in Self.kernelNames {
                if let f = library.makeFunction(name: name) { pipelines[name] = try device.makeComputePipelineState(function: f) }
            }
            AppLog.info("metal", "Metal preview backend ready on \(device.name)")
        } catch {
            AppLog.error("metal", "Metal kernel compilation failed: \(error)")
        }
    }

    func buffer<T>(_ values: [T]) -> MTLBuffer? {
        guard let device else { return nil }
        return values.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
    }

    func emptyBuffer<T>(count: Int, of: T.Type) -> MTLBuffer? {
        device?.makeBuffer(length: count * MemoryLayout<T>.stride, options: .storageModeShared)
    }

    func cachedBuffer<T>(_ key: String, _ values: [T]) -> MTLBuffer? {
        lock.lock()
        if let existing = immutableBuffers[key] {
            immutableBufferLRU.removeAll { $0 == key }
            immutableBufferLRU.append(key)
            lock.unlock()
            return existing
        }
        lock.unlock()
        guard let created = buffer(values) else { return nil }
        lock.lock()
        // Another worker may have inserted the same immutable resource while the
        // buffer was being allocated. Prefer that instance and discard ours.
        if let existing = immutableBuffers[key] {
            immutableBufferLRU.removeAll { $0 == key }
            immutableBufferLRU.append(key)
            lock.unlock()
            return existing
        }
        immutableBuffers[key] = created
        immutableBufferLRU.append(key)
        while immutableBufferLRU.count > immutableBufferLimit, let evict = immutableBufferLRU.first {
            immutableBufferLRU.removeFirst()
            immutableBuffers.removeValue(forKey: evict)
        }
        lock.unlock()
        return created
    }

    /// Lazily constructs immutable CPU data only on a cache miss. This is important
    /// for large TC/profile tables: a cache hit must not still pay Double→Float conversion.
    func cachedBufferLazy<T>(_ key: String, makeValues: () -> [T]) -> MTLBuffer? {
        lock.lock()
        if let existing = immutableBuffers[key] {
            immutableBufferLRU.removeAll { $0 == key }; immutableBufferLRU.append(key); lock.unlock(); return existing
        }
        lock.unlock()
        let values = makeValues()
        return cachedBuffer(key, values)
    }

    public func prewarmTCLUT(_ lut: TCLUT, cacheKey: String) {
        _ = cachedBufferLazy("lut:\(cacheKey):\(lut.width)x\(lut.height):\(lut.data.count)") { lut.data.map(Float.init) }
    }

    public func purgeCaches() {
        lock.lock()
        immutableBuffers.removeAll(keepingCapacity: false)
        immutableBufferLRU.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func dispatch(_ name: String, count: Int, encode: (MTLComputeCommandEncoder) -> Void) -> Bool {
        guard count > 0, let pipeline = pipelines[name] else { return false }
        if let batch = currentResidentBatch {
            guard let enc = batch.commandBuffer.makeComputeCommandEncoder() else { return false }
            enc.setComputePipelineState(pipeline); encode(enc)
            let w = min(pipeline.maxTotalThreadsPerThreadgroup, max(pipeline.threadExecutionWidth, 64))
            enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
            enc.endEncoding()
            return true
        }
        acquireGPUSlot(); defer { releaseGPUSlot() }
        guard let queue, let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(pipeline); encode(enc)
        let w = min(pipeline.maxTotalThreadsPerThreadgroup, max(pipeline.threadExecutionWidth, 64))
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        return cb.status == .completed
    }

    func pack(_ image: LinearRGBImage) -> [SIMD4<Float>] {
        var v = [SIMD4<Float>](); v.reserveCapacity(image.width * image.height)
        for i in 0..<(image.width * image.height) { v.append(SIMD4(Float(image.pixels[i*3]), Float(image.pixels[i*3+1]), Float(image.pixels[i*3+2]), 0)) }
        return v
    }
    func unpack(_ b: MTLBuffer, width: Int, height: Int) -> LinearRGBImage {
        let p = b.contents().bindMemory(to: SIMD4<Float>.self, capacity: width*height)
        var out = LinearRGBImage(width: width, height: height)
        for i in 0..<(width*height) { out.pixels[i*3]=Double(p[i].x); out.pixels[i*3+1]=Double(p[i].y); out.pixels[i*3+2]=Double(p[i].z) }
        return out
    }

}

extension Array { subscript(safe i:Int)->Element? { indices.contains(i) ? self[i] : nil } }
#else
public final class MetalAccelerator: @unchecked Sendable {
    public static let shared = MetalAccelerator(); public var isAvailable: Bool { false }; private init() {}
    public func gaussianBlur(_ image: LinearRGBImage, sigmas: [Double]) -> LinearRGBImage? { nil }
    public func rgbToFilmRaw(_ image: LinearRGBImage, lut: TCLUT, sourceToXYZ: ColorScience.Mat3, adaptation: ColorScience.Mat3, cacheKey: String = "default") -> LinearRGBImage? { nil }
    public func printExposure(_ density: LinearRGBImage, channelDensity: [[Double?]], baseDensity: [[Double?]], sensitivity: [[Double]], illuminant: [Double], preflash: [Double], scale: Double, cacheKey: String = "default") -> LinearRGBImage? { nil }
    public func densityToRGB(_ density: LinearRGBImage, channelDensity: [[Double?]], baseDensity: [[Double?]], cmfs: [[Double]], illuminant: [Double], norm: Double, transform: ColorScience.Mat3, cacheKey: String = "default") -> LinearRGBImage? { nil }
    public func grainSimple(_ density: LinearRGBImage, params: GrainParameters, densityMax: [Double], pixelSizeMicrometers: Double) -> LinearRGBImage? { nil }
    public func grainLayers(_ density: LinearRGBImage, params: GrainParameters, xAxes: [Float], yAxes: [Float], densityMax: [Float], densityMin: [Float], fractions: [Float], curveCount: Int, positive: Bool, pixelSizeMicrometers: Double) -> LinearRGBImage? { nil }
    public func develop(_ logExposure: LinearRGBImage, axis: [Double], curves: [[Double]], gamma: Double, cacheKey: String) -> LinearRGBImage? { nil }
    public func dirInhibitor(_ density: LinearRGBImage, matrix: [[Double]], maxDensity: [Double], positive: Bool) -> LinearRGBImage? { nil }
    public func dirRedevelop(_ logRaw: LinearRGBImage, inhibitor: LinearRGBImage, axis: [Double], curves: [[Double]], gamma: Double, cacheKey: String) -> LinearRGBImage? { nil }
    public func exponentialBlur(_ image: LinearRGBImage, decay: [Double]) -> LinearRGBImage? { nil }
    public func purgeCaches() {}
}
#endif
