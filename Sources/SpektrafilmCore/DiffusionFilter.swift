import Foundation

public enum DiffusionFilterModel {
    private struct Group { var lambda: Double; var spread: Double; var count: Int; var alpha: Double? }
    private struct Family { var core: Group; var halo: Group; var bloom: Group; var weights: [Double]; var warmth: Double; var gain: Double }
    private static let families: [String: Family] = [
        "glimmerglass": .init(core:.init(lambda:10,spread:1.5,count:2,alpha:nil), halo:.init(lambda:50,spread:2,count:3,alpha:nil), bloom:.init(lambda:260,spread:2.5,count:4,alpha:3.2), weights:[0.60,0.30,0.10], warmth:0, gain:0.65),
        "black_pro_mist": .init(core:.init(lambda:16,spread:1.5,count:2,alpha:nil), halo:.init(lambda:95,spread:2,count:3,alpha:nil), bloom:.init(lambda:380,spread:2.5,count:4,alpha:3.5), weights:[0.40,0.47,0.13], warmth:0.65, gain:0.75),
        "pro_mist": .init(core:.init(lambda:14,spread:1.5,count:2,alpha:nil), halo:.init(lambda:150,spread:2,count:3,alpha:nil), bloom:.init(lambda:650,spread:2.5,count:4,alpha:2.9), weights:[0.28,0.42,0.30], warmth:0.40, gain:1.05),
        "cinebloom": .init(core:.init(lambda:20,spread:1.5,count:2,alpha:nil), halo:.init(lambda:200,spread:2,count:3,alpha:nil), bloom:.init(lambda:1000,spread:2.5,count:4,alpha:2.5), weights:[0.22,0.30,0.48], warmth:0.85, gain:1.00),
    ]
    private static let breaks=[0.125,0.25,0.5,1.0,2.0], fractions=[0.10,0.20,0.35,0.55,0.75]
    private static let warmthAxis=[1.30,0.15,-1.45]

    public static func apply(_ image: LinearRGBImage, parameters p: DiffusionFilterParameters, pixelSizeMicrometers: Double, useGPU: Bool = false) -> LinearRGBImage {
        guard p.active, p.strength > 0, p.spatialScale > 0, let base = families[p.family] else { return image }
        let scatter = min(max(interp(log2(max(p.strength,1e-6)), xs: breaks.map(log2), ys: fractions) * base.gain,0),0.99)
        guard scatter > 0 else { return image }
        var groupWeights=[base.weights[0]*max(p.coreIntensity,0), base.weights[1]*max(p.haloIntensity,0), base.weights[2]*max(p.bloomIntensity,0)]
        let gwSum=max(groupWeights.reduce(0,+),1e-30); groupWeights=groupWeights.map{$0/gwSum}
        let pixel=max(pixelSizeMicrometers,1e-9)
        let core=expanded(base.core, size:p.coreSize).map{($0.0*p.spatialScale/pixel,$0.1)}
        let halo=expanded(base.halo, size:p.haloSize).map{($0.0*p.spatialScale/pixel,$0.1)}
        let bloom=expanded(base.bloom, size:p.bloomSize).map{($0.0*p.spatialScale/pixel,$0.1)}
        let warmth=min(max(base.warmth+p.haloWarmth,-1.5),1.5)
        let haloWeights=perChannelHaloWeights(halo.map{$0.1}, warmth:warmth)
        var blurred=LinearRGBImage(width:image.width,height:image.height)
        addMixture(&blurred, source:image, components:core, groupWeight:groupWeights[0], channelWeights:nil, useGPU:useGPU)
        addMixture(&blurred, source:image, components:halo, groupWeight:groupWeights[1], channelWeights:haloWeights, useGPU:useGPU)
        addMixture(&blurred, source:image, components:bloom, groupWeight:groupWeights[2], channelWeights:nil, useGPU:useGPU)
        var out=image
        for i in out.pixels.indices { out.pixels[i]=(1-scatter)*image.pixels[i]+scatter*blurred.pixels[i] }
        return out
    }

    private static func addMixture(_ out: inout LinearRGBImage, source: LinearRGBImage, components:[(Double,Double)], groupWeight:Double, channelWeights:[[Double]]?, useGPU:Bool) {
        for (index,component) in components.enumerated() {
            let b=Convolution.exponentialBlur(source, decay:[component.0,component.0,component.0], useGPU:useGPU)
            for y in 0..<out.height { for x in 0..<out.width { for c in 0..<3 {
                let w=(channelWeights?[c][index] ?? component.1)*groupWeight
                out[x,y,c] += b[x,y,c]*w
            }}}
        }
    }
    private static func expanded(_ g:Group,size:Double)->[(Double,Double)] {
        let n=max(g.count,1), center=g.lambda*max(size,1e-6)
        if n==1 || g.spread<=1 { return [(center,1)] }
        let lo=log(center/g.spread), hi=log(center*g.spread)
        var vals=(0..<n).map { exp(lo+(hi-lo)*Double($0)/Double(n-1)) }
        var ws:[Double]
        if let alpha=g.alpha { ws=vals.map{pow($0,2-alpha)} } else { ws=Array(repeating:1,count:n) }
        let sum=max(ws.reduce(0,+),1e-30); ws=ws.map{$0/sum}
        return Array(zip(vals,ws))
    }
    private static func perChannelHaloWeights(_ base:[Double],warmth:Double)->[[Double]] {
        guard base.count>1 else { return Array(repeating:base,count:3) }
        var gradient=(0..<base.count).map{-1+2*Double($0)/Double(base.count-1)}
        let mean=zip(gradient,base).reduce(0){$0+$1.0*$1.1}/max(base.reduce(0,+),1e-30); gradient=gradient.map{$0-mean}
        return (0..<3).map { c in
            var raw=zip(base,gradient).map{max($0.0*(1+warmth*warmthAxis[c]*$0.1),0)}
            let s=max(raw.reduce(0,+),1e-30), target=base.reduce(0,+); raw=raw.map{$0*target/s}; return raw
        }
    }
    private static func interp(_ q:Double,xs:[Double],ys:[Double])->Double {
        if q<=xs[0] { return ys[0] }; if q>=xs.last! { return ys.last! }
        for i in 0..<xs.count-1 where q<=xs[i+1] { let t=(q-xs[i])/(xs[i+1]-xs[i]); return ys[i]*(1-t)+ys[i+1]*t }; return ys.last!
    }
#if canImport(Metal)
    public static func applyResident(_ image: MetalAccelerator.ResidentImage, parameters p: DiffusionFilterParameters, pixelSizeMicrometers: Double) -> MetalAccelerator.ResidentImage? {
        guard p.active, p.strength > 0, p.spatialScale > 0, let base = families[p.family] else { return image }
        let scatter = min(max(interp(log2(max(p.strength,1e-6)), xs: breaks.map(log2), ys: fractions) * base.gain,0),0.99)
        guard scatter > 0 else { return image }
        var groupWeights=[base.weights[0]*max(p.coreIntensity,0), base.weights[1]*max(p.haloIntensity,0), base.weights[2]*max(p.bloomIntensity,0)]
        let gwSum=max(groupWeights.reduce(0,+),1e-30); groupWeights=groupWeights.map{$0/gwSum}
        let pixel=max(pixelSizeMicrometers,1e-9)
        let core=expanded(base.core, size:p.coreSize).map{($0.0*p.spatialScale/pixel,$0.1)}
        let halo=expanded(base.halo, size:p.haloSize).map{($0.0*p.spatialScale/pixel,$0.1)}
        let bloom=expanded(base.bloom, size:p.bloomSize).map{($0.0*p.spatialScale/pixel,$0.1)}
        let warmth=min(max(base.warmth+p.haloWarmth,-1.5),1.5)
        let haloWeights=perChannelHaloWeights(halo.map{$0.1}, warmth:warmth)
        var blurred: MetalAccelerator.ResidentImage?
        func add(_ components:[(Double,Double)], _ groupWeight:Double, _ channelWeights:[[Double]]?) -> Bool {
            for (index, component) in components.enumerated() {
                guard let b = MetalAccelerator.shared.exponentialBlurResident(image, decay:[component.0,component.0,component.0]) else { return false }
                let wr = (channelWeights?[0][index] ?? component.1) * groupWeight
                let wg = (channelWeights?[1][index] ?? component.1) * groupWeight
                let wb = (channelWeights?[2][index] ?? component.1) * groupWeight
                guard let scaled = MetalAccelerator.shared.combineChannelsResident(b, b, weightA: SIMD3<Double>(wr,wg,wb), weightB: .zero) else { return false }
                if let current = blurred { blurred = MetalAccelerator.shared.linearCombineResident(current, scaled, weightA: 1, weightB: 1) } else { blurred = scaled }
            }
            return true
        }
        guard add(core,groupWeights[0],nil), add(halo,groupWeights[1],haloWeights), add(bloom,groupWeights[2],nil), let blurred,
              let out = MetalAccelerator.shared.linearCombineResident(image, blurred, weightA: 1-scatter, weightB: scatter) else { return nil }
        return out
    }
#endif

}
