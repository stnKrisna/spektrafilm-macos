import Foundation

#if canImport(Metal)
import Metal

extension MetalAccelerator {
    // MARK: - GPU-resident preview images

    /// Float32 image that remains resident in a shared Metal buffer between preview stages.
    /// It is intentionally scoped to the interactive preview path; the f64 CPU path remains
    /// the export/parity reference.
    public final class ResidentImage: @unchecked Sendable {
        fileprivate let buffer: MTLBuffer
        public let width: Int
        public let height: Int
        fileprivate init(buffer: MTLBuffer, width: Int, height: Int) {
            self.buffer = buffer; self.width = width; self.height = height
        }
        fileprivate var count: Int { width * height }
    }

    public func uploadResident(_ image: LinearRGBImage) -> ResidentImage? {
        guard isAvailable else { return nil }
        let packed = pack(image)
        guard let b = buffer(packed) else { return nil }
        return ResidentImage(buffer: b, width: image.width, height: image.height)
    }

    public func downloadResident(_ image: ResidentImage) -> LinearRGBImage {
        unpack(image.buffer, width: image.width, height: image.height)
    }

    public func rgbToFilmRawResident(_ image: ResidentImage, lut: TCLUT, sourceToXYZ: ColorScience.Mat3, adaptation: ColorScience.Mat3, cacheKey: String) -> ResidentImage? {
        guard let out = residentOutput(like: image),
              let lb = cachedBufferLazy("lut:\(cacheKey):\(lut.width)x\(lut.height):\(lut.data.count)", makeValues: { lut.data.map(Float.init) }),
              let mb = cachedBufferLazy("rgbmat:\(cacheKey)", makeValues: { (sourceToXYZ + adaptation).flatMap { $0 }.map(Float.init) }) else { return nil }
        var dims = SIMD2<UInt32>(UInt32(lut.height), UInt32(lut.width))
        let ok = dispatch("rgb_to_film_raw", count: image.count) { e in
            e.setBuffer(image.buffer, offset: 0, index: 0); e.setBuffer(out.buffer, offset: 0, index: 1)
            e.setBuffer(lb, offset: 0, index: 2); e.setBuffer(mb, offset: 0, index: 3)
            e.setBytes(&dims, length: MemoryLayout.size(ofValue: dims), index: 4)
        }
        return ok ? out : nil
    }

    public func scaleResident(_ image: ResidentImage, scale: Double) -> ResidentImage? {
        guard let out = residentOutput(like: image) else { return nil }
        var s = Float(scale)
        let ok = dispatch("scale_rgb", count: image.count) { e in
            e.setBuffer(image.buffer, offset: 0, index: 0); e.setBuffer(out.buffer, offset: 0, index: 1); e.setBytes(&s, length: 4, index: 2)
        }
        return ok ? out : nil
    }

    public func boostHighlightsResident(_ image: ResidentImage, boostEV: Double, boostRange: Double, protectEV: Double, midgray: Double = 0.184) -> ResidentImage? {
        guard boostEV > 0 else { return image }
        guard let maxBuffer = emptyBuffer(count: 1, of: UInt32.self), let out = residentOutput(like: image) else { return nil }
        maxBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        guard dispatch("reduce_max_rgb", count: image.count, encode: { e in
            e.setBuffer(image.buffer, offset: 0, index: 0); e.setBuffer(maxBuffer, offset: 0, index: 1)
        }) else { return nil }
        var p = SIMD4<Float>(Float(boostEV), Float(boostRange), Float(protectEV), Float(midgray))
        let ok = dispatch("boost_highlights", count: image.count) { e in
            e.setBuffer(image.buffer, offset: 0, index: 0); e.setBuffer(out.buffer, offset: 0, index: 1)
            e.setBuffer(maxBuffer, offset: 0, index: 2); e.setBytes(&p, length: MemoryLayout.size(ofValue: p), index: 3)
        }
        return ok ? out : nil
    }

    public func linearCombineResident(_ a: ResidentImage, _ b: ResidentImage, weightA: Double, weightB: Double) -> ResidentImage? {
        guard a.width == b.width, a.height == b.height, let out = residentOutput(like: a) else { return nil }
        var weights = SIMD2<Float>(Float(weightA), Float(weightB))
        let ok = dispatch("linear_combine", count: a.count) { e in
            e.setBuffer(a.buffer, offset: 0, index: 0); e.setBuffer(b.buffer, offset: 0, index: 1); e.setBuffer(out.buffer, offset: 0, index: 2); e.setBytes(&weights, length: MemoryLayout.size(ofValue: weights), index: 3)
        }
        return ok ? out : nil
    }

    public func combineChannelsResident(_ a: ResidentImage, _ b: ResidentImage, weightA: SIMD3<Double>, weightB: SIMD3<Double>) -> ResidentImage? {
        guard a.width == b.width, a.height == b.height, let out = residentOutput(like: a) else { return nil }
        var wa = SIMD4<Float>(Float(weightA.x), Float(weightA.y), Float(weightA.z), 0)
        var wb = SIMD4<Float>(Float(weightB.x), Float(weightB.y), Float(weightB.z), 0)
        let ok = dispatch("combine_channels", count: a.count) { e in
            e.setBuffer(a.buffer, offset: 0, index: 0); e.setBuffer(b.buffer, offset: 0, index: 1); e.setBuffer(out.buffer, offset: 0, index: 2)
            e.setBytes(&wa, length: MemoryLayout.size(ofValue: wa), index: 3); e.setBytes(&wb, length: MemoryLayout.size(ofValue: wb), index: 4)
        }
        return ok ? out : nil
    }

    /// Copy the final resident float4 buffer to a shader-readable Metal texture without CPU readback.
    public func textureResident(_ image: ResidentImage, cropX: Int = 0, cropY: Int = 0, cropWidth: Int? = nil, cropHeight: Int? = nil) -> MTLTexture? {
        guard let device else { return nil }
        let x = min(max(cropX, 0), max(image.width - 1, 0)), y = min(max(cropY, 0), max(image.height - 1, 0))
        let width = min(max(cropWidth ?? (image.width - x), 1), image.width - x)
        let height = min(max(cropHeight ?? (image.height - y), 1), image.height - y)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        func encodeBlit(_ cb: MTLCommandBuffer) -> Bool {
            guard let blit = cb.makeBlitCommandEncoder() else { return false }
            let stride = MemoryLayout<SIMD4<Float>>.stride
            let sourceOffset = (y * image.width + x) * stride
            blit.copy(from: image.buffer, sourceOffset: sourceOffset, sourceBytesPerRow: image.width * stride, sourceBytesPerImage: image.width * image.height * stride, sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding(); return true
        }
        if let batch = currentResidentBatch { return encodeBlit(batch.commandBuffer) ? texture : nil }
        acquireGPUSlot(); defer { releaseGPUSlot() }
        guard let queue, let cb = queue.makeCommandBuffer(), encodeBlit(cb) else { return nil }
        cb.commit(); cb.waitUntilCompleted(); return cb.status == .completed ? texture : nil
    }

    private func residentOutput(like image: ResidentImage) -> ResidentImage? {
        guard let b = emptyBuffer(count: image.count, of: SIMD4<Float>.self) else { return nil }
        return ResidentImage(buffer: b, width: image.width, height: image.height)
    }

    public func log10Resident(_ image: ResidentImage, epsilon: Double = 1e-10) -> ResidentImage? {
        guard let out = residentOutput(like: image) else { return nil }
        var eps = Float(epsilon)
        let ok = dispatch("log10_transform", count: image.count) { e in
            e.setBuffer(image.buffer, offset: 0, index: 0); e.setBuffer(out.buffer, offset: 0, index: 1)
            e.setBytes(&eps, length: 4, index: 2)
        }
        return ok ? out : nil
    }

    public func developResident(_ input: ResidentImage, axis: [Double], curves: [[Double]], gamma: Double, cacheKey: String) -> ResidentImage? {
        guard axis.count >= 2, curves.count == axis.count, let out = residentOutput(like: input) else { return nil }
        let n = axis.count
        guard let ab = cachedBufferLazy("resident:develop:\(cacheKey):axis", makeValues: { axis.map(Float.init) }),
              let cb = cachedBufferLazy("resident:develop:\(cacheKey):curves", makeValues: {
                  var cv = [Float](repeating: 0, count: n * 3)
                  for i in 0..<n { for c in 0..<3 { cv[i*3+c] = Float(curves[i][min(c, curves[i].count-1)]) } }
                  return cv
              }) else { return nil }
        var count = UInt32(n), g = Float(max(gamma, 1e-12))
        let ok = dispatch("develop_linear", count: input.count) { e in
            e.setBuffer(input.buffer,offset:0,index:0); e.setBuffer(out.buffer,offset:0,index:1); e.setBuffer(ab,offset:0,index:2); e.setBuffer(cb,offset:0,index:3); e.setBytes(&count,length:4,index:4); e.setBytes(&g,length:4,index:5)
        }
        return ok ? out : nil
    }

    public func dirInhibitorResident(_ density: ResidentImage, matrix: [[Double]], maxDensity: [Double], positive: Bool) -> ResidentImage? {
        guard let out = residentOutput(like: density) else { return nil }
        var m = [Float](repeating: 0, count: 9); for r in 0..<3 { for c in 0..<3 { m[r*3+c] = Float(matrix[r][c]) } }
        guard let mb = buffer(m) else { return nil }
        var md = SIMD4<Float>(Float(maxDensity[0]),Float(maxDensity[1]),Float(maxDensity[2]),0), pos = UInt32(positive ? 1 : 0)
        let ok = dispatch("dir_inhibitor", count: density.count) { e in
            e.setBuffer(density.buffer,offset:0,index:0);e.setBuffer(out.buffer,offset:0,index:1);e.setBuffer(mb,offset:0,index:2);e.setBytes(&md,length:MemoryLayout.size(ofValue:md),index:3);e.setBytes(&pos,length:4,index:4)
        }
        return ok ? out : nil
    }

    public func gaussianBlurResident(_ image: ResidentImage, sigmas: [Double]) -> ResidentImage? {
        guard let hp = pipelines["gaussian_h"], let vp = pipelines["gaussian_v"], let tmp = residentOutput(like: image), let out = residentOutput(like: image) else { return nil }
        let ownsCommandBuffer = currentResidentBatch == nil
        if ownsCommandBuffer { acquireGPUSlot() }
        defer { if ownsCommandBuffer { releaseGPUSlot() } }
        guard let cb = currentResidentBatch?.commandBuffer ?? queue?.makeCommandBuffer() else { return nil }
        var sig = SIMD4<Float>(Float(sigmas[safe:0] ?? 0), Float(sigmas[safe:1] ?? sigmas.last ?? 0), Float(sigmas[safe:2] ?? sigmas.last ?? 0), 0)
        var radius = Int32(max(1, Int(ceil(3 * max(Double(sig.x), max(Double(sig.y), Double(sig.z)))))))
        var wh = SIMD2<UInt32>(UInt32(image.width), UInt32(image.height))
        func enc(_ p: MTLComputePipelineState, _ src: MTLBuffer, _ dst: MTLBuffer) -> Bool {
            guard let e = cb.makeComputeCommandEncoder() else { return false }
            e.setComputePipelineState(p);e.setBuffer(src,offset:0,index:0);e.setBuffer(dst,offset:0,index:1);e.setBytes(&wh,length:MemoryLayout.size(ofValue:wh),index:2);e.setBytes(&sig,length:MemoryLayout.size(ofValue:sig),index:3);e.setBytes(&radius,length:4,index:4)
            let w=min(p.maxTotalThreadsPerThreadgroup,max(p.threadExecutionWidth,64));e.dispatchThreads(MTLSize(width:image.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:w,height:1,depth:1));e.endEncoding();return true
        }
        guard enc(hp,image.buffer,tmp.buffer), enc(vp,tmp.buffer,out.buffer) else { return nil }
        if ownsCommandBuffer { cb.commit(); cb.waitUntilCompleted(); return cb.status == .completed ? out : nil }
        return out
    }

    public func exponentialBlurResident(_ image: ResidentImage, decay: [Double]) -> ResidentImage? {
        guard let hp=pipelines["gaussian_h"], let vp=pipelines["gaussian_v"], let ap=pipelines["accumulate_weighted"], let tmp=residentOutput(like:image), let blurred=residentOutput(like:image), let accum=residentOutput(like:image) else{return nil}
        let ownsCommandBuffer=currentResidentBatch == nil
        if ownsCommandBuffer { acquireGPUSlot() }
        defer { if ownsCommandBuffer { releaseGPUSlot() } }
        guard let cb=currentResidentBatch?.commandBuffer ?? queue?.makeCommandBuffer() else{return nil}
        accum.buffer.contents().initializeMemory(as: UInt8.self, repeating: 0, count: image.count*MemoryLayout<SIMD4<Float>>.stride)
        var wh=SIMD2<UInt32>(UInt32(image.width),UInt32(image.height)); let fit:[(Float,Double)]=[(0.1633,0.5360),(0.6496,1.5236),(0.1870,2.7684)]
        func threads(_ p:MTLComputePipelineState)->MTLSize{MTLSize(width:min(p.maxTotalThreadsPerThreadgroup,max(p.threadExecutionWidth,64)),height:1,depth:1)}
        for (amp,ratio) in fit {
            var sig=SIMD4<Float>(Float((decay[safe:0] ?? 0)*ratio),Float((decay[safe:1] ?? decay.last ?? 0)*ratio),Float((decay[safe:2] ?? decay.last ?? 0)*ratio),0); var r=Int32(max(1,Int(ceil(3*max(Double(sig.x),max(Double(sig.y),Double(sig.z)))))))
            for (p,sb,db) in [(hp,image.buffer,tmp.buffer),(vp,tmp.buffer,blurred.buffer)] { guard let e=cb.makeComputeCommandEncoder() else{return nil};e.setComputePipelineState(p);e.setBuffer(sb,offset:0,index:0);e.setBuffer(db,offset:0,index:1);e.setBytes(&wh,length:MemoryLayout.size(ofValue:wh),index:2);e.setBytes(&sig,length:MemoryLayout.size(ofValue:sig),index:3);e.setBytes(&r,length:4,index:4);e.dispatchThreads(MTLSize(width:image.count,height:1,depth:1),threadsPerThreadgroup:threads(p));e.endEncoding() }
            guard let e=cb.makeComputeCommandEncoder() else{return nil};var weight=amp;e.setComputePipelineState(ap);e.setBuffer(blurred.buffer,offset:0,index:0);e.setBuffer(accum.buffer,offset:0,index:1);e.setBytes(&weight,length:4,index:2);e.dispatchThreads(MTLSize(width:image.count,height:1,depth:1),threadsPerThreadgroup:threads(ap));e.endEncoding()
        }
        if ownsCommandBuffer { cb.commit();cb.waitUntilCompleted();return cb.status == .completed ? accum:nil }
        return accum
    }

    public func blendResident(_ a: ResidentImage, _ b: ResidentImage, weightB: Double) -> ResidentImage? {
        guard a.width == b.width, a.height == b.height, let out = residentOutput(like: a) else { return nil }
        var w = Float(weightB)
        let ok=dispatch("blend_buffers",count:a.count){e in e.setBuffer(a.buffer,offset:0,index:0);e.setBuffer(b.buffer,offset:0,index:1);e.setBuffer(out.buffer,offset:0,index:2);e.setBytes(&w,length:4,index:3)}
        return ok ? out:nil
    }

    public func dirRedevelopResident(_ logRaw: ResidentImage, inhibitor: ResidentImage, axis: [Double], curves: [[Double]], gamma: Double, cacheKey: String) -> ResidentImage? {
        guard logRaw.width == inhibitor.width, logRaw.height == inhibitor.height, axis.count >= 2, curves.count == axis.count, let out=residentOutput(like:logRaw) else{return nil}
        let n=axis.count
        guard let xb=cachedBufferLazy("resident:dir:\(cacheKey):axis", makeValues: { axis.map(Float.init) }),
              let cb=cachedBufferLazy("resident:dir:\(cacheKey):curves", makeValues: {
                  var cv=[Float](repeating:0,count:n*3); for i in 0..<n{for c in 0..<3{cv[i*3+c]=Float(curves[i][min(c,curves[i].count-1)])}}; return cv
              }) else{return nil};var count=UInt32(n),g=Float(max(gamma,1e-12))
        let ok=dispatch("dir_redevelop",count:logRaw.count){e in e.setBuffer(logRaw.buffer,offset:0,index:0);e.setBuffer(inhibitor.buffer,offset:0,index:1);e.setBuffer(out.buffer,offset:0,index:2);e.setBuffer(xb,offset:0,index:3);e.setBuffer(cb,offset:0,index:4);e.setBytes(&count,length:4,index:5);e.setBytes(&g,length:4,index:6)}
        return ok ? out:nil
    }

    public func grainSimpleResident(_ density: ResidentImage, params: GrainParameters, densityMax: [Double], pixelSizeMicrometers: Double, sourceOrigin: SIMD2<UInt32> = .zero, sourceWidth: UInt32 = 0, renderScale: Double = 1) -> ResidentImage? {
        guard let out=residentOutput(like:density) else{return nil}
        var dmax=SIMD4<Float>(Float(densityMax[safe:0] ?? 2.2),Float(densityMax[safe:1] ?? 2.2),Float(densityMax[safe:2] ?? 2.2),0),dmin=SIMD4<Float>(Float(params.densityMin[safe:0] ?? 0),Float(params.densityMin[safe:1] ?? 0),Float(params.densityMin[safe:2] ?? 0),0),scale=SIMD4<Float>(Float(params.particleScale[safe:0] ?? 1),Float(params.particleScale[safe:1] ?? 1),Float(params.particleScale[safe:2] ?? 1),0),uniform=SIMD4<Float>(Float(params.uniformity[safe:0] ?? 1),Float(params.uniformity[safe:1] ?? 1),Float(params.uniformity[safe:2] ?? 1),0)
        var area=Float(params.particleAreaMicrometers2),pixelArea=Float(pixelSizeMicrometers*pixelSizeMicrometers),sub=UInt32(max(params.numberOfSublayers,1)),seed=params.seed
        var origin=sourceOrigin, srcWidth=max(sourceWidth,UInt32(density.width)), localWidth=UInt32(density.width), invScale=Float(1.0/max(renderScale,0.01))
        let ok=dispatch("grain_simple",count:density.count){e in e.setBuffer(density.buffer,offset:0,index:0);e.setBuffer(out.buffer,offset:0,index:1);e.setBytes(&dmax,length:MemoryLayout.size(ofValue:dmax),index:2);e.setBytes(&dmin,length:MemoryLayout.size(ofValue:dmin),index:3);e.setBytes(&scale,length:MemoryLayout.size(ofValue:scale),index:4);e.setBytes(&uniform,length:MemoryLayout.size(ofValue:uniform),index:5);e.setBytes(&area,length:4,index:6);e.setBytes(&pixelArea,length:4,index:7);e.setBytes(&sub,length:4,index:8);e.setBytes(&seed,length:8,index:9);e.setBytes(&origin,length:MemoryLayout.size(ofValue:origin),index:10);e.setBytes(&srcWidth,length:4,index:11);e.setBytes(&localWidth,length:4,index:12);e.setBytes(&invScale,length:4,index:13)}
        return ok ? out:nil
    }

    public func grainLayersResident(_ density: ResidentImage, params: GrainParameters, xAxes: [Float], yAxes: [Float], densityMax: [Float], densityMin: [Float], fractions: [Float], curveCount: Int, positive: Bool, pixelSizeMicrometers: Double, sourceOrigin: SIMD2<UInt32> = .zero, sourceWidth: UInt32 = 0, renderScale: Double = 1) -> ResidentImage? {
        guard curveCount>1,let out=residentOutput(like:density),let xb=cachedBuffer("resident:grain:x:\(xAxes.hashValue)",xAxes),let yb=cachedBuffer("resident:grain:y:\(yAxes.hashValue)",yAxes),let db=cachedBuffer("resident:grain:dmax:\(densityMax.hashValue)",densityMax),let mib=cachedBuffer("resident:grain:dmin:\(densityMin.hashValue)",densityMin),let fb=cachedBuffer("resident:grain:frac:\(fractions.hashValue)",fractions),let sb=cachedBuffer("resident:grain:scale:\(params.particleScale.hashValue):\(params.uniformity.hashValue)",(params.particleScale+params.uniformity).map(Float.init)) else{return nil}
        var ls=SIMD4<Float>(Float(params.particleScaleLayers[safe:0] ?? 1),Float(params.particleScaleLayers[safe:1] ?? 1),Float(params.particleScaleLayers[safe:2] ?? 1),0),area=Float(params.particleAreaMicrometers2),pixelArea=Float(pixelSizeMicrometers*pixelSizeMicrometers),n=UInt32(curveCount),pos=UInt32(positive ? 1:0),seed=params.seed
        var origin=sourceOrigin, srcWidth=max(sourceWidth,UInt32(density.width)), localWidth=UInt32(density.width), invScale=Float(1.0/max(renderScale,0.01))
        let ok=dispatch("grain_layers",count:density.count){e in e.setBuffer(density.buffer,offset:0,index:0);e.setBuffer(out.buffer,offset:0,index:1);e.setBuffer(xb,offset:0,index:2);e.setBuffer(yb,offset:0,index:3);e.setBuffer(db,offset:0,index:4);e.setBuffer(mib,offset:0,index:5);e.setBuffer(fb,offset:0,index:6);e.setBuffer(sb,offset:0,index:7);e.setBytes(&ls,length:MemoryLayout.size(ofValue:ls),index:8);e.setBytes(&area,length:4,index:9);e.setBytes(&pixelArea,length:4,index:10);e.setBytes(&n,length:4,index:11);e.setBytes(&pos,length:4,index:12);e.setBytes(&seed,length:8,index:13);e.setBytes(&origin,length:MemoryLayout.size(ofValue:origin),index:14);e.setBytes(&srcWidth,length:4,index:15);e.setBytes(&localWidth,length:4,index:16);e.setBytes(&invScale,length:4,index:17)}
        return ok ? out:nil
    }

    public func printExposureResident(_ density: ResidentImage, channelDensity: [[Double?]], baseDensity: [[Double?]], sensitivity: [[Double]], illuminant: [Double], preflash: [Double], scale: Double, cacheKey: String) -> ResidentImage? {
        let n=min(illuminant.count,min(channelDensity.count,sensitivity.count));guard n>0,let out=residentOutput(like:density) else{return nil}
        func valid(_ i:Int) -> Bool { let row=channelDensity[i],br=i<baseDensity.count ? baseDensity[i]:nil; return row.count>=3 && row[0] != nil && row[1] != nil && row[2] != nil && (br == nil || br!.allSatisfy{$0 != nil}) }
        guard let cdb=cachedBufferLazy("resident:print:\(cacheKey):cd", makeValues:{ var v=[Float](repeating:0,count:n*3); for i in 0..<n { for c in 0..<3 where c<channelDensity[i].count { v[i*3+c]=Float(channelDensity[i][c] ?? 0) } }; return v }),
              let bb=cachedBufferLazy("resident:print:\(cacheKey):base", makeValues:{ (0..<n).map { i in i<baseDensity.count ? Float(baseDensity[i].compactMap{$0}.reduce(0,+)) : 0 } }),
              let sb=cachedBufferLazy("resident:print:\(cacheKey):sens", makeValues:{ var v=[Float](repeating:0,count:n*3); for i in 0..<n { for c in 0..<3 where c<sensitivity[i].count { v[i*3+c]=Float(sensitivity[i][c]) } }; return v }),
              let ilb=cachedBufferLazy("resident:print:\(cacheKey):illum", makeValues:{ (0..<n).map { Float(illuminant[$0]) } }),
              let okb=cachedBufferLazy("resident:print:\(cacheKey):mask", makeValues:{ (0..<n).map { valid($0) ? 1.0 : 0.0 } }) else{return nil}
        var nw=UInt32(n),pf=SIMD4<Float>(Float(preflash[safe:0] ?? 0),Float(preflash[safe:1] ?? 0),Float(preflash[safe:2] ?? 0),0),sc=Float(scale)
        let ok=dispatch("print_exposure",count:density.count){e in e.setBuffer(density.buffer,offset:0,index:0);e.setBuffer(out.buffer,offset:0,index:1);e.setBuffer(cdb,offset:0,index:2);e.setBuffer(bb,offset:0,index:3);e.setBuffer(sb,offset:0,index:4);e.setBuffer(ilb,offset:0,index:5);e.setBytes(&nw,length:4,index:6);e.setBytes(&pf,length:MemoryLayout.size(ofValue:pf),index:7);e.setBytes(&sc,length:4,index:8);e.setBuffer(okb,offset:0,index:9)}
        return ok ? out:nil
    }

    public func densityToRGBResident(_ density: ResidentImage, channelDensity: [[Double?]], baseDensity: [[Double?]], cmfs: [[Double]], illuminant: [Double], norm: Double, transform: ColorScience.Mat3, cacheKey: String) -> ResidentImage? {
        let n=min(channelDensity.count,min(cmfs.count,illuminant.count));guard n>0,let out=residentOutput(like:density) else{return nil};var cd=[Float](repeating:0,count:n*3),base=[Float](repeating:0,count:n),cmf=[Float](repeating:0,count:n*3),illum=[Float](repeating:0,count:n),mask=[Float](repeating:0,count:n)
        for i in 0..<n{let row=channelDensity[i],cr=cmfs[i],br=i<baseDensity.count ? baseDensity[i]:nil;let valid=row.count>=3 && row[0] != nil && row[1] != nil && row[2] != nil && cr.count>=3 && (br == nil || br!.allSatisfy{$0 != nil});mask[i]=valid ? 1:0;illum[i]=Float(illuminant[i]);if i<baseDensity.count{base[i]=Float(baseDensity[i].compactMap{$0}.reduce(0,+))};for c in 0..<3{if c<row.count{cd[i*3+c]=Float(row[c] ?? 0)};if c<cr.count{cmf[i*3+c]=Float(cr[c])}}}
        guard let cdb=cachedBuffer("resident:scan:\(cacheKey):cd",cd),let bb=cachedBuffer("resident:scan:\(cacheKey):base",base),let cb=cachedBuffer("resident:scan:\(cacheKey):cmf",cmf),let ilb=cachedBuffer("resident:scan:\(cacheKey):illum",illum),let okb=cachedBuffer("resident:scan:\(cacheKey):mask",mask) else{return nil};var nw=UInt32(n),nm=Float(norm);let m=transform.flatMap{$0}.map(Float.init);guard let mb=buffer(m) else{return nil}
        let ok=dispatch("density_to_rgb",count:density.count){e in e.setBuffer(density.buffer,offset:0,index:0);e.setBuffer(out.buffer,offset:0,index:1);e.setBuffer(cdb,offset:0,index:2);e.setBuffer(bb,offset:0,index:3);e.setBuffer(cb,offset:0,index:4);e.setBuffer(ilb,offset:0,index:5);e.setBytes(&nw,length:4,index:6);e.setBytes(&nm,length:4,index:7);e.setBuffer(mb,offset:0,index:8);e.setBuffer(okb,offset:0,index:9)}
        return ok ? out:nil
    }

    public func densityToRGBGamutResident(
        _ density: ResidentImage,
        channelDensity: [[Double?]], baseDensity: [[Double?]], cmfs: [[Double]], illuminant: [Double], norm: Double,
        transform: ColorScience.Mat3, cacheKey: String,
        glareField: ResidentImage?, glareWhiteRGB: SIMD3<Double>,
        colorSpace: String, gamut: OutputGamutCompressionParameters
    ) -> ResidentImage? {
        let n = min(channelDensity.count, min(cmfs.count, illuminant.count))
        guard n > 0, let out = residentOutput(like: density) else { return nil }
        // For non-sRGB outputs the CPU reference currently treats output gamut compression
        // as identity, so keep the fused path but disable its CAM16 portion.
        let gamutActive = gamut.active && colorSpace.lowercased() == "srgb"
        func valid(_ i:Int) -> Bool {
            let row=channelDensity[i], cr=cmfs[i], br=i<baseDensity.count ? baseDensity[i]:nil
            return row.count>=3 && row[0] != nil && row[1] != nil && row[2] != nil && cr.count>=3 && (br == nil || br!.allSatisfy{$0 != nil})
        }
        guard let cdb=cachedBufferLazy("resident:scanfinish:\(cacheKey):cd", makeValues: { var v=[Float](repeating:0,count:n*3); for i in 0..<n { for c in 0..<3 where c<channelDensity[i].count { v[i*3+c]=Float(channelDensity[i][c] ?? 0) } }; return v }),
              let bb=cachedBufferLazy("resident:scanfinish:\(cacheKey):base", makeValues: { (0..<n).map { i in i<baseDensity.count ? Float(baseDensity[i].compactMap{$0}.reduce(0,+)) : 0 } }),
              let cmb=cachedBufferLazy("resident:scanfinish:\(cacheKey):cmf", makeValues: { var v=[Float](repeating:0,count:n*3); for i in 0..<n { for c in 0..<3 where c<cmfs[i].count { v[i*3+c]=Float(cmfs[i][c]) } }; return v }),
              let ilb=cachedBufferLazy("resident:scanfinish:\(cacheKey):illum", makeValues: { (0..<n).map { Float(illuminant[$0]) } }),
              let okb=cachedBufferLazy("resident:scanfinish:\(cacheKey):mask", makeValues: { (0..<n).map { valid($0) ? 1.0 : 0.0 } }),
              let mb=cachedBufferLazy("resident:scanfinish:\(cacheKey):matrix", makeValues: { transform.flatMap{$0}.map(Float.init) }) else { return nil }
        var nw=UInt32(n), nm=Float(norm)
        let p=GamutCompression.metalPayload; guard let table=cachedBuffer("cam16:sRGB:cmax:\(p.nL)x\(p.nH)",p.cMax) else { return nil }
        var env0=SIMD4<Float>(p.fl,p.flRoot,p.n,p.z), env1=SIMD4<Float>(p.nbb,p.ncb,p.c,p.nc), env2=SIMD4<Float>(p.aw,p.jpWhite,p.minL,p.maxL)
        var dr=SIMD4<Float>(p.dRGB.x,p.dRGB.y,p.dRGB.z,0), dri=SIMD4<Float>(p.dRGBInv.x,p.dRGBInv.y,p.dRGBInv.z,0), dims=SIMD2<UInt32>(UInt32(p.nL),UInt32(p.nH))
        var kp=SIMD4<Float>(Float(gamut.threshold),Float(gamut.limit),Float(gamut.power),gamutActive ? 1:0)
        let gf=glareField?.buffer ?? density.buffer; var gs=SIMD4<Float>(Float(glareWhiteRGB.x),Float(glareWhiteRGB.y),Float(glareWhiteRGB.z),glareField == nil ? 0:1)
        let ok=dispatch("density_to_rgb_cam16",count:density.count){e in
            e.setBuffer(density.buffer,offset:0,index:0);e.setBuffer(out.buffer,offset:0,index:1);e.setBuffer(cdb,offset:0,index:2);e.setBuffer(bb,offset:0,index:3);e.setBuffer(cmb,offset:0,index:4);e.setBuffer(ilb,offset:0,index:5);e.setBytes(&nw,length:4,index:6);e.setBytes(&nm,length:4,index:7);e.setBuffer(mb,offset:0,index:8);e.setBuffer(okb,offset:0,index:9);e.setBuffer(gf,offset:0,index:10);e.setBytes(&gs,length:MemoryLayout.size(ofValue:gs),index:11);e.setBuffer(table,offset:0,index:12);e.setBytes(&env0,length:MemoryLayout.size(ofValue:env0),index:13);e.setBytes(&env1,length:MemoryLayout.size(ofValue:env1),index:14);e.setBytes(&env2,length:MemoryLayout.size(ofValue:env2),index:15);e.setBytes(&dr,length:MemoryLayout.size(ofValue:dr),index:16);e.setBytes(&dri,length:MemoryLayout.size(ofValue:dri),index:17);e.setBytes(&dims,length:MemoryLayout.size(ofValue:dims),index:18);e.setBytes(&kp,length:MemoryLayout.size(ofValue:kp),index:19)
        }
        return ok ? out:nil
    }

    public func addScaledResident(_ image: ResidentImage, field: ResidentImage, scale: SIMD3<Double>) -> ResidentImage? {
        guard image.width == field.width, image.height == field.height, let out = residentOutput(like: image) else { return nil }
        var s = SIMD4<Float>(Float(scale.x), Float(scale.y), Float(scale.z), 0)
        let ok = dispatch("add_scaled", count: image.count) { e in
            e.setBuffer(image.buffer, offset: 0, index: 0); e.setBuffer(field.buffer, offset: 0, index: 1); e.setBuffer(out.buffer, offset: 0, index: 2)
            e.setBytes(&s, length: MemoryLayout.size(ofValue: s), index: 3)
        }
        return ok ? out : nil
    }

    public func gamutCompressResident(_ image: ResidentImage, colorSpace: String, parameters: OutputGamutCompressionParameters) -> ResidentImage? {
        guard parameters.active else { return image }
        guard colorSpace.lowercased() == "srgb" else { return image }
        guard let out = residentOutput(like: image) else { return nil }
        let p = GamutCompression.metalPayload
        guard let table = cachedBuffer("cam16:sRGB:cmax:\(p.nL)x\(p.nH)", p.cMax) else { return nil }
        var env0 = SIMD4<Float>(p.fl, p.flRoot, p.n, p.z)
        var env1 = SIMD4<Float>(p.nbb, p.ncb, p.c, p.nc)
        var env2 = SIMD4<Float>(p.aw, p.jpWhite, p.minL, p.maxL)
        var dr = SIMD4<Float>(p.dRGB.x, p.dRGB.y, p.dRGB.z, 0)
        var dri = SIMD4<Float>(p.dRGBInv.x, p.dRGBInv.y, p.dRGBInv.z, 0)
        var dims = SIMD2<UInt32>(UInt32(p.nL), UInt32(p.nH))
        var knee = SIMD4<Float>(Float(parameters.threshold), Float(parameters.limit), Float(parameters.power), 0)
        let ok = dispatch("gamut_compress_cam16", count: image.count) { e in
            e.setBuffer(image.buffer, offset: 0, index: 0); e.setBuffer(out.buffer, offset: 0, index: 1); e.setBuffer(table, offset: 0, index: 2)
            e.setBytes(&env0, length: MemoryLayout.size(ofValue: env0), index: 3); e.setBytes(&env1, length: MemoryLayout.size(ofValue: env1), index: 4)
            e.setBytes(&env2, length: MemoryLayout.size(ofValue: env2), index: 5); e.setBytes(&dr, length: MemoryLayout.size(ofValue: dr), index: 6)
            e.setBytes(&dri, length: MemoryLayout.size(ofValue: dri), index: 7); e.setBytes(&dims, length: MemoryLayout.size(ofValue: dims), index: 8)
            e.setBytes(&knee, length: MemoryLayout.size(ofValue: knee), index: 9)
        }
        return ok ? out : nil
    }

    public func unsharpResident(_ image: ResidentImage, sigma: Double, amount: Double) -> ResidentImage? {
        guard amount != 0 else { return image }
        guard let blurred = gaussianBlurResident(image, sigmas: [sigma, sigma, sigma]), let out = residentOutput(like: image) else { return nil }
        var a = Float(amount)
        let ok = dispatch("unsharp_combine", count: image.count) { e in
            e.setBuffer(image.buffer, offset: 0, index: 0); e.setBuffer(blurred.buffer, offset: 0, index: 1); e.setBuffer(out.buffer, offset: 0, index: 2)
            e.setBytes(&a, length: 4, index: 3)
        }
        return ok ? out : nil
    }

    public func scannerFinishResident(_ image: ResidentImage, parameters: ScannerParameters, io: IOParameters, spatialOff: Bool, gamutAlreadyApplied: Bool = false) -> ResidentImage? {
        var work = image
        if !gamutAlreadyApplied {
            guard let gamut = gamutCompressResident(work, colorSpace: io.outputColorSpace, parameters: io.outputGamutCompression) else { return nil }
            work = gamut
        }
        if !spatialOff, parameters.lensBlur > 0 {
            guard let b = gaussianBlurResident(work, sigmas: [parameters.lensBlur, parameters.lensBlur, parameters.lensBlur]) else { return nil }
            work = b
        }
        if !spatialOff, parameters.unsharpAmount != 0 {
            guard let u = unsharpResident(work, sigma: max(parameters.unsharpSigma, 0.01), amount: parameters.unsharpAmount) else { return nil }
            work = u
        }
        guard let out = residentOutput(like: work) else { return nil }
        let black = parameters.blackCorrection ? parameters.blackLevel : 0
        let white = parameters.whiteCorrection ? parameters.whiteLevel : 1
        var levels = SIMD4<Float>(Float(black), Float(white), parameters.blackCorrection || parameters.whiteCorrection ? 1 : 0, 0)
        let lower = io.outputColorSpace.lowercased()
        let mode: UInt32
        if !io.outputCCTFEncoding { mode = 0 }
        else if lower == "prophoto rgb" || lower == "prophoto" { mode = 2 }
        else if ["adobe rgb (1998)", "adobe rgb", "adobergb", "display p3", "p3", "itu-r bt.2020", "rec.2020", "bt.2020", "bt2020", "acescg"].contains(lower) { mode = 0 }
        else { mode = 1 }
        var cctf = mode
        let ok = dispatch("scanner_finish", count: work.count) { e in
            e.setBuffer(work.buffer, offset: 0, index: 0); e.setBuffer(out.buffer, offset: 0, index: 1)
            e.setBytes(&levels, length: MemoryLayout.size(ofValue: levels), index: 2); e.setBytes(&cctf, length: 4, index: 3)
        }
        return ok ? out : nil
    }
}
#endif
