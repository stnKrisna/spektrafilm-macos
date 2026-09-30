import Foundation

#if canImport(Metal)
import Metal

extension MetalAccelerator {
    public func gaussianBlur(_ image: LinearRGBImage, sigmas: [Double]) -> LinearRGBImage? {
        guard isAvailable, let queue, let hp = pipelines["gaussian_h"], let vp = pipelines["gaussian_v"] else { return nil }
        let s = SIMD4<Float>(Float(sigmas[safe:0] ?? 0), Float(sigmas[safe:1] ?? sigmas.last ?? 0), Float(sigmas[safe:2] ?? sigmas.last ?? 0), 0)
        let radius = Int32(max(1, Int(ceil(3 * max(Double(s.x), max(Double(s.y), Double(s.z)))))))
        let input = pack(image)
        acquireGPUSlot(); defer { releaseGPUSlot() }
        guard let a=buffer(input), let b=emptyBuffer(count: input.count, of: SIMD4<Float>.self), let c=emptyBuffer(count: input.count, of: SIMD4<Float>.self), let cb=queue.makeCommandBuffer() else { return nil }
        var wh = SIMD2<UInt32>(UInt32(image.width), UInt32(image.height)); var sig=s; var r=radius
        func encode(_ pipeline: MTLComputePipelineState, _ src: MTLBuffer, _ dst: MTLBuffer) -> Bool {
            guard let e=cb.makeComputeCommandEncoder() else { return false }
            e.setComputePipelineState(pipeline); e.setBuffer(src,offset:0,index:0); e.setBuffer(dst,offset:0,index:1); e.setBytes(&wh,length:MemoryLayout.size(ofValue:wh),index:2); e.setBytes(&sig,length:MemoryLayout.size(ofValue:sig),index:3); e.setBytes(&r,length:4,index:4)
            let w=min(pipeline.maxTotalThreadsPerThreadgroup,max(pipeline.threadExecutionWidth,64)); e.dispatchThreads(MTLSize(width:input.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:w,height:1,depth:1)); e.endEncoding(); return true
        }
        guard encode(hp,a,b), encode(vp,b,c) else { return nil }
        cb.commit(); cb.waitUntilCompleted(); return cb.status == .completed ? unpack(c,width:image.width,height:image.height) : nil
    }

    public func rgbToFilmRaw(_ image: LinearRGBImage, lut: TCLUT, sourceToXYZ: ColorScience.Mat3, adaptation: ColorScience.Mat3, cacheKey: String = "default") -> LinearRGBImage? {
        guard isAvailable else { return nil }
        let input=pack(image)
        guard let ib=buffer(input),let ob=emptyBuffer(count:input.count,of:SIMD4<Float>.self),let lb=cachedBufferLazy("lut:\(cacheKey):\(lut.width)x\(lut.height):\(lut.data.count)", makeValues: { lut.data.map(Float.init) }) else{return nil}
        let m=(sourceToXYZ+adaptation).flatMap{$0}.map(Float.init); guard let mb=buffer(m) else{return nil}; var dims=SIMD2<UInt32>(UInt32(lut.height),UInt32(lut.width))
        let ok=dispatch("rgb_to_film_raw",count:input.count){e in e.setBuffer(ib,offset:0,index:0);e.setBuffer(ob,offset:0,index:1);e.setBuffer(lb,offset:0,index:2);e.setBuffer(mb,offset:0,index:3);e.setBytes(&dims,length:MemoryLayout.size(ofValue:dims),index:4)}
        return ok ? unpack(ob,width:image.width,height:image.height) : nil
    }

    public func printExposure(_ density: LinearRGBImage, channelDensity: [[Double?]], baseDensity: [[Double?]], sensitivity: [[Double]], illuminant: [Double], preflash: [Double], scale: Double, cacheKey: String = "default") -> LinearRGBImage? {
        guard isAvailable else{return nil}; let n=min(illuminant.count,min(channelDensity.count,sensitivity.count));guard n>0 else{return nil}
        let input=pack(density); var cd=[Float](repeating:0,count:n*3),sens=[Float](repeating:0,count:n*3),base=[Float](repeating:0,count:n),illum=[Float](repeating:0,count:n),mask=[Float](repeating:0,count:n)
        for i in 0..<n {
            let cdRow = i < channelDensity.count ? channelDensity[i] : []
            let baseRow = i < baseDensity.count ? baseDensity[i] : nil
            let baseValid = baseRow == nil || baseRow!.allSatisfy({ $0 != nil })
            let valid = cdRow.count >= 3 && cdRow[0] != nil && cdRow[1] != nil && cdRow[2] != nil && baseValid
            mask[i] = valid ? 1.0 : 0.0
            illum[i]=Float(illuminant[i]); if i<baseDensity.count { base[i]=Float(baseDensity[i].compactMap{$0}.reduce(0,+)) }; for c in 0..<3 { if c<channelDensity[i].count {cd[i*3+c]=Float(channelDensity[i][c] ?? 0)}; if c<sensitivity[i].count {sens[i*3+c]=Float(sensitivity[i][c])} }
        }
        guard let ib=buffer(input),let ob=emptyBuffer(count:input.count,of:SIMD4<Float>.self),let cdb=cachedBuffer("print:\(cacheKey):cd",cd),let bb=cachedBuffer("print:\(cacheKey):base",base),let sb=cachedBuffer("print:\(cacheKey):sens",sens),let ilb=cachedBuffer("print:\(cacheKey):illum",illum),let okb=cachedBuffer("print:\(cacheKey):mask",mask) else{return nil}
        var nw=UInt32(n), pf=SIMD4<Float>(Float(preflash[safe:0] ?? 0),Float(preflash[safe:1] ?? 0),Float(preflash[safe:2] ?? 0),0), sc=Float(scale)
        let ok=dispatch("print_exposure",count:input.count){e in e.setBuffer(ib,offset:0,index:0);e.setBuffer(ob,offset:0,index:1);e.setBuffer(cdb,offset:0,index:2);e.setBuffer(bb,offset:0,index:3);e.setBuffer(sb,offset:0,index:4);e.setBuffer(ilb,offset:0,index:5);e.setBytes(&nw,length:4,index:6);e.setBytes(&pf,length:MemoryLayout.size(ofValue:pf),index:7);e.setBytes(&sc,length:4,index:8);e.setBuffer(okb,offset:0,index:9)}
        return ok ? unpack(ob,width:density.width,height:density.height) : nil
    }

    public func densityToRGB(_ density: LinearRGBImage, channelDensity: [[Double?]], baseDensity: [[Double?]], cmfs: [[Double]], illuminant: [Double], norm: Double, transform: ColorScience.Mat3, cacheKey: String = "default") -> LinearRGBImage? {
        guard isAvailable else{return nil};let n=min(channelDensity.count,min(cmfs.count,illuminant.count));guard n>0 else{return nil}
        let input=pack(density);var cd=[Float](repeating:0,count:n*3),base=[Float](repeating:0,count:n),cmf=[Float](repeating:0,count:n*3),illum=[Float](repeating:0,count:n),mask=[Float](repeating:0,count:n)
        for i in 0..<n {
            let cdRow = i < channelDensity.count ? channelDensity[i] : []
            let cmfRow = i < cmfs.count ? cmfs[i] : []
            let baseRow = i < baseDensity.count ? baseDensity[i] : nil
            let baseValid = baseRow == nil || baseRow!.allSatisfy({ $0 != nil })
            let valid = cdRow.count >= 3 && cdRow[0] != nil && cdRow[1] != nil && cdRow[2] != nil && cmfRow.count >= 3 && baseValid
            mask[i] = valid ? 1.0 : 0.0
            illum[i]=Float(illuminant[i]);if i<baseDensity.count{base[i]=Float(baseDensity[i].compactMap{$0}.reduce(0,+))};for c in 0..<3{if c<channelDensity[i].count{cd[i*3+c]=Float(channelDensity[i][c] ?? 0)};if c<cmfs[i].count{cmf[i*3+c]=Float(cmfs[i][c])}}
        }
        guard let ib=buffer(input),let ob=emptyBuffer(count:input.count,of:SIMD4<Float>.self),let cdb=cachedBuffer("scan:\(cacheKey):cd",cd),let bb=cachedBuffer("scan:\(cacheKey):base",base),let cb=cachedBuffer("scan:\(cacheKey):cmf",cmf),let ilb=cachedBuffer("scan:\(cacheKey):illum",illum),let okb=cachedBuffer("scan:\(cacheKey):mask",mask) else{return nil}
        var nw=UInt32(n),nm=Float(norm);let m=transform.flatMap{$0}.map(Float.init);guard let mb=buffer(m) else{return nil}
        let ok=dispatch("density_to_rgb",count:input.count){e in e.setBuffer(ib,offset:0,index:0);e.setBuffer(ob,offset:0,index:1);e.setBuffer(cdb,offset:0,index:2);e.setBuffer(bb,offset:0,index:3);e.setBuffer(cb,offset:0,index:4);e.setBuffer(ilb,offset:0,index:5);e.setBytes(&nw,length:4,index:6);e.setBytes(&nm,length:4,index:7);e.setBuffer(mb,offset:0,index:8);e.setBuffer(okb,offset:0,index:9)}
        return ok ? unpack(ob,width:density.width,height:density.height) : nil
    }

    public func develop(_ logExposure: LinearRGBImage, axis: [Double], curves: [[Double]], gamma: Double, cacheKey: String) -> LinearRGBImage? {
        guard isAvailable, axis.count >= 2, curves.count == axis.count else { return nil }
        let input=pack(logExposure); let n=axis.count
        var ax=axis.map(Float.init), cv=[Float](repeating:0,count:n*3)
        for i in 0..<n { for c in 0..<3 { cv[i*3+c]=Float(curves[i][min(c,curves[i].count-1)]) } }
        guard let ib=buffer(input),let ob=emptyBuffer(count:input.count,of:SIMD4<Float>.self),let ab=cachedBuffer("develop:\(cacheKey):axis",ax),let cb=cachedBuffer("develop:\(cacheKey):curves",cv) else{return nil}
        var count=UInt32(n), g=Float(max(gamma,1e-12))
        let ok=dispatch("develop_linear",count:input.count){e in e.setBuffer(ib,offset:0,index:0);e.setBuffer(ob,offset:0,index:1);e.setBuffer(ab,offset:0,index:2);e.setBuffer(cb,offset:0,index:3);e.setBytes(&count,length:4,index:4);e.setBytes(&g,length:4,index:5)}
        return ok ? unpack(ob,width:logExposure.width,height:logExposure.height) : nil
    }

    public func dirInhibitor(_ density: LinearRGBImage, matrix: [[Double]], maxDensity: [Double], positive: Bool) -> LinearRGBImage? {
        guard isAvailable else{return nil}; let input=pack(density)
        guard let ib=buffer(input),let ob=emptyBuffer(count:input.count,of:SIMD4<Float>.self) else{return nil}
        var m=[Float](repeating:0,count:9); for r in 0..<3 { for c in 0..<3 { m[r*3+c]=Float(matrix[r][c]) } }
        var md=SIMD4<Float>(Float(maxDensity[0]),Float(maxDensity[1]),Float(maxDensity[2]),0), pos=UInt32(positive ? 1:0)
        guard let mb=buffer(m) else{return nil}
        let ok=dispatch("dir_inhibitor",count:input.count){e in e.setBuffer(ib,offset:0,index:0);e.setBuffer(ob,offset:0,index:1);e.setBuffer(mb,offset:0,index:2);e.setBytes(&md,length:MemoryLayout.size(ofValue:md),index:3);e.setBytes(&pos,length:4,index:4)}
        return ok ? unpack(ob,width:density.width,height:density.height) : nil
    }

    public func dirRedevelop(_ logRaw: LinearRGBImage, inhibitor: LinearRGBImage, axis: [Double], curves: [[Double]], gamma: Double, cacheKey: String) -> LinearRGBImage? {
        guard isAvailable, axis.count >= 2, curves.count == axis.count, logRaw.width == inhibitor.width, logRaw.height == inhibitor.height else{return nil}
        let a=pack(logRaw), b=pack(inhibitor), n=axis.count; let ax=axis.map(Float.init); var cv=[Float](repeating:0,count:n*3)
        for i in 0..<n { for c in 0..<3 { cv[i*3+c]=Float(curves[i][min(c,curves[i].count-1)]) } }
        guard let ab=buffer(a),let bb=buffer(b),let ob=emptyBuffer(count:a.count,of:SIMD4<Float>.self),let xb=cachedBuffer("dir:\(cacheKey):axis",ax),let cb=cachedBuffer("dir:\(cacheKey):curves",cv) else{return nil}
        var count=UInt32(n),g=Float(max(gamma,1e-12))
        let ok=dispatch("dir_redevelop",count:a.count){e in e.setBuffer(ab,offset:0,index:0);e.setBuffer(bb,offset:0,index:1);e.setBuffer(ob,offset:0,index:2);e.setBuffer(xb,offset:0,index:3);e.setBuffer(cb,offset:0,index:4);e.setBytes(&count,length:4,index:5);e.setBytes(&g,length:4,index:6)}
        return ok ? unpack(ob,width:logRaw.width,height:logRaw.height) : nil
    }

    public func exponentialBlur(_ image: LinearRGBImage, decay: [Double]) -> LinearRGBImage? {
        guard isAvailable, let queue, let hp=pipelines["gaussian_h"], let vp=pipelines["gaussian_v"], let ap=pipelines["accumulate_weighted"] else{return nil}
        let input=pack(image), count=input.count
        acquireGPUSlot(); defer { releaseGPUSlot() }
        guard let src=buffer(input),let tmp=emptyBuffer(count:count,of:SIMD4<Float>.self),let blurred=emptyBuffer(count:count,of:SIMD4<Float>.self),let accum=emptyBuffer(count:count,of:SIMD4<Float>.self),let cb=queue.makeCommandBuffer() else{return nil}
        accum.contents().initializeMemory(as: UInt8.self, repeating: 0, count: count*MemoryLayout<SIMD4<Float>>.stride)
        var wh=SIMD2<UInt32>(UInt32(image.width),UInt32(image.height))
        let fit:[(Float,Double)]=[(0.1633,0.5360),(0.6496,1.5236),(0.1870,2.7684)]
        func threads(_ p:MTLComputePipelineState)->MTLSize{MTLSize(width:min(p.maxTotalThreadsPerThreadgroup,max(p.threadExecutionWidth,64)),height:1,depth:1)}
        for (amp,ratio) in fit {
            var sig=SIMD4<Float>(Float((decay[safe:0] ?? 0)*ratio),Float((decay[safe:1] ?? decay.last ?? 0)*ratio),Float((decay[safe:2] ?? decay.last ?? 0)*ratio),0)
            var r=Int32(max(1,Int(ceil(3*max(Double(sig.x),max(Double(sig.y),Double(sig.z)))))))
            for (p,sb,db) in [(hp,src,tmp),(vp,tmp,blurred)] { guard let e=cb.makeComputeCommandEncoder() else{return nil}; e.setComputePipelineState(p);e.setBuffer(sb,offset:0,index:0);e.setBuffer(db,offset:0,index:1);e.setBytes(&wh,length:MemoryLayout.size(ofValue:wh),index:2);e.setBytes(&sig,length:MemoryLayout.size(ofValue:sig),index:3);e.setBytes(&r,length:4,index:4);e.dispatchThreads(MTLSize(width:count,height:1,depth:1),threadsPerThreadgroup:threads(p));e.endEncoding() }
            guard let e=cb.makeComputeCommandEncoder() else{return nil}; var weight=amp;e.setComputePipelineState(ap);e.setBuffer(blurred,offset:0,index:0);e.setBuffer(accum,offset:0,index:1);e.setBytes(&weight,length:4,index:2);e.dispatchThreads(MTLSize(width:count,height:1,depth:1),threadsPerThreadgroup:threads(ap));e.endEncoding()
        }
        cb.commit();cb.waitUntilCompleted();return cb.status == .completed ? unpack(accum,width:image.width,height:image.height):nil
    }

    public func grainSimple(_ density: LinearRGBImage, params: GrainParameters, densityMax: [Double], pixelSizeMicrometers: Double) -> LinearRGBImage? {
        guard isAvailable else { return nil }
        let input=pack(density); guard let ib=buffer(input), let ob=emptyBuffer(count:input.count,of:SIMD4<Float>.self) else { return nil }
        var dmax=SIMD4<Float>(Float(densityMax[safe:0] ?? 2.2),Float(densityMax[safe:1] ?? 2.2),Float(densityMax[safe:2] ?? 2.2),0)
        var dmin=SIMD4<Float>(Float(params.densityMin[safe:0] ?? 0),Float(params.densityMin[safe:1] ?? 0),Float(params.densityMin[safe:2] ?? 0),0)
        var scale=SIMD4<Float>(Float(params.particleScale[safe:0] ?? 1),Float(params.particleScale[safe:1] ?? 1),Float(params.particleScale[safe:2] ?? 1),0)
        var uniform=SIMD4<Float>(Float(params.uniformity[safe:0] ?? 1),Float(params.uniformity[safe:1] ?? 1),Float(params.uniformity[safe:2] ?? 1),0)
        var area=Float(params.particleAreaMicrometers2), pixelArea=Float(pixelSizeMicrometers*pixelSizeMicrometers), sub=UInt32(max(params.numberOfSublayers,1)), seed=params.seed
        let ok=dispatch("grain_simple",count:input.count){e in e.setBuffer(ib,offset:0,index:0);e.setBuffer(ob,offset:0,index:1);e.setBytes(&dmax,length:MemoryLayout.size(ofValue:dmax),index:2);e.setBytes(&dmin,length:MemoryLayout.size(ofValue:dmin),index:3);e.setBytes(&scale,length:MemoryLayout.size(ofValue:scale),index:4);e.setBytes(&uniform,length:MemoryLayout.size(ofValue:uniform),index:5);e.setBytes(&area,length:4,index:6);e.setBytes(&pixelArea,length:4,index:7);e.setBytes(&sub,length:4,index:8);e.setBytes(&seed,length:8,index:9);var origin=SIMD2<UInt32>(0,0),srcWidth=UInt32(density.width),localWidth=UInt32(density.width),invScale:Float=1;e.setBytes(&origin,length:MemoryLayout.size(ofValue:origin),index:10);e.setBytes(&srcWidth,length:4,index:11);e.setBytes(&localWidth,length:4,index:12);e.setBytes(&invScale,length:4,index:13)}
        return ok ? unpack(ob,width:density.width,height:density.height) : nil
    }

    public func grainLayers(_ density: LinearRGBImage, params: GrainParameters, xAxes: [Float], yAxes: [Float], densityMax: [Float], densityMin: [Float], fractions: [Float], curveCount: Int, positive: Bool, pixelSizeMicrometers: Double) -> LinearRGBImage? {
        guard isAvailable, curveCount > 1 else { return nil }
        let input=pack(density)
        guard let ib=buffer(input), let ob=emptyBuffer(count:input.count,of:SIMD4<Float>.self), let xb=buffer(xAxes), let yb=buffer(yAxes), let maxb=buffer(densityMax), let minb=buffer(densityMin), let fb=buffer(fractions) else { return nil }
        var scales=[Float](repeating:1,count:6); for c in 0..<3 { scales[c]=Float(params.particleScale[safe:c] ?? 1); scales[3+c]=Float(params.uniformity[safe:c] ?? 1) }
        guard let sb=buffer(scales) else { return nil }
        var layerScale=SIMD4<Float>(Float(params.particleScaleLayers[safe:0] ?? 1),Float(params.particleScaleLayers[safe:1] ?? 1),Float(params.particleScaleLayers[safe:2] ?? 1),0)
        var area=Float(params.particleAreaMicrometers2), pixelArea=Float(pixelSizeMicrometers*pixelSizeMicrometers), n=UInt32(curveCount), pos=UInt32(positive ? 1:0), seed=params.seed
        let ok=dispatch("grain_layers",count:input.count){e in e.setBuffer(ib,offset:0,index:0);e.setBuffer(ob,offset:0,index:1);e.setBuffer(xb,offset:0,index:2);e.setBuffer(yb,offset:0,index:3);e.setBuffer(maxb,offset:0,index:4);e.setBuffer(minb,offset:0,index:5);e.setBuffer(fb,offset:0,index:6);e.setBuffer(sb,offset:0,index:7);e.setBytes(&layerScale,length:MemoryLayout.size(ofValue:layerScale),index:8);e.setBytes(&area,length:4,index:9);e.setBytes(&pixelArea,length:4,index:10);e.setBytes(&n,length:4,index:11);e.setBytes(&pos,length:4,index:12);e.setBytes(&seed,length:8,index:13);var origin=SIMD2<UInt32>(0,0),srcWidth=UInt32(density.width),localWidth=UInt32(density.width),invScale:Float=1;e.setBytes(&origin,length:MemoryLayout.size(ofValue:origin),index:14);e.setBytes(&srcWidth,length:4,index:15);e.setBytes(&localWidth,length:4,index:16);e.setBytes(&invScale,length:4,index:17)}
        return ok ? unpack(ob,width:density.width,height:density.height) : nil
    }
}
#endif
