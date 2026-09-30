import Foundation

/// Literal port of the monotone cubic strategy used by spektrafilm-rs pchip3d.rs.
public struct PreparedPCHIP3D: Sendable {
    public let size: Int
    public let channels: Int
    public let values: [Double]
    public let slopeX: [Double]
    public let slopeY: [Double]
    public let slopeZ: [Double]
    private let cellMin: [Double]
    private let cellMax: [Double]

    public init(size: Int, channels: Int, values: [Double]) {
        precondition(size >= 2 && channels > 0 && values.count == size * size * size * channels)
        self.size = size; self.channels = channels; self.values = values
        var sx = Array(repeating: 0.0, count: values.count)
        var sy = sx, sz = sx
        func idx(_ x: Int, _ y: Int, _ z: Int, _ c: Int) -> Int { (((z*size+y)*size+x)*channels+c) }
        for z in 0..<size { for y in 0..<size { for c in 0..<channels {
            let line = (0..<size).map { values[idx($0,y,z,c)] }
            let s = Self.slopes(line)
            for x in 0..<size { sx[idx(x,y,z,c)] = s[x] }
        }}}
        for z in 0..<size { for x in 0..<size { for c in 0..<channels {
            let line = (0..<size).map { values[idx(x,$0,z,c)] }
            let s = Self.slopes(line)
            for y in 0..<size { sy[idx(x,y,z,c)] = s[y] }
        }}}
        for y in 0..<size { for x in 0..<size { for c in 0..<channels {
            let line = (0..<size).map { values[idx(x,y,$0,c)] }
            let s = Self.slopes(line)
            for z in 0..<size { sz[idx(x,y,z,c)] = s[z] }
        }}}
        slopeX=sx; slopeY=sy; slopeZ=sz
        let cells=(size-1)*(size-1)*(size-1)*channels
        var mins=Array(repeating: Double.infinity,count:cells), maxs=Array(repeating:-Double.infinity,count:cells)
        func ci(_ x:Int,_ y:Int,_ z:Int,_ c:Int)->Int { (((z*(size-1)+y)*(size-1)+x)*channels+c) }
        for z in 0..<(size-1) { for y in 0..<(size-1) { for x in 0..<(size-1) { for c in 0..<channels {
            let q=ci(x,y,z,c)
            for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
                let v=values[idx(x+dx,y+dy,z+dz,c)]; mins[q]=min(mins[q],v); maxs[q]=max(maxs[q],v)
            }}}
        }}}}
        cellMin=mins; cellMax=maxs
    }

    public func sample(x: Double, y: Double, z: Double, channel c: Int) -> Double {
        precondition(c >= 0 && c < channels)
        let (ix,tx)=Self.baseFraction(x,size), (iy,ty)=Self.baseFraction(y,size), (iz,tz)=Self.baseFraction(z,size)
        func idx(_ x:Int,_ y:Int,_ z:Int)->Int { (((z*size+y)*size+x)*channels+c) }
        var vx=Array(repeating:0.0,count:4), my=Array(repeating:0.0,count:4), mz=Array(repeating:0.0,count:4)
        var k=0
        for dz in 0...1 { for dy in 0...1 {
            let a=idx(ix,iy+dy,iz+dz), b=idx(ix+1,iy+dy,iz+dz)
            vx[k]=Self.hermite(values[a],values[b],slopeX[a],slopeX[b],tx)
            my[k]=slopeY[a]*(1-tx)+slopeY[b]*tx
            mz[k]=slopeZ[a]*(1-tx)+slopeZ[b]*tx
            k += 1
        }}
        let y0=Self.hermite(vx[0],vx[1],my[0],my[1],ty)
        let y1=Self.hermite(vx[2],vx[3],my[2],my[3],ty)
        let z0=mz[0]*(1-ty)+mz[1]*ty, z1=mz[2]*(1-ty)+mz[3]*ty
        let v=Self.hermite(y0,y1,z0,z1,tz)
        let ci=(((iz*(size-1)+iy)*(size-1)+ix)*channels+c)
        return min(max(v,cellMin[ci]),cellMax[ci])
    }

    private static func baseFraction(_ q: Double,_ n:Int)->(Int,Double) {
        let u=min(max(q,0),Double(n-1)); if u>=Double(n-1){ return(n-2,1) }
        let i=Int(floor(u)); return(i,u-Double(i))
    }
    private static func hermite(_ y0:Double,_ y1:Double,_ m0:Double,_ m1:Double,_ t:Double)->Double {
        let t2=t*t,t3=t2*t
        return (2*t3-3*t2+1)*y0 + (t3-2*t2+t)*m0 + (-2*t3+3*t2)*y1 + (t3-t2)*m1
    }
    private static func slopes(_ y:[Double])->[Double] {
        let n=y.count; if n==1{return[0]}; if n==2{let d=y[1]-y[0];return[d,d]}
        let d=(0..<(n-1)).map{y[$0+1]-y[$0]}; var m=Array(repeating:0.0,count:n)
        var l=0.5*(3*d[0]-d[1]); if l*d[0]<=0 {l=0} else if d[0]*d[1]<0 && abs(l)>abs(3*d[0]) {l=3*d[0]}; m[0]=l
        for i in 1..<(n-1) { let a=d[i-1],b=d[i]; m[i]=(a==0 || b==0 || a*b<=0) ? 0 : 2*a*b/(a+b) }
        var r=0.5*(3*d[n-2]-d[n-3]); if r*d[n-2]<=0 {r=0} else if d[n-2]*d[n-3]<0 && abs(r)>abs(3*d[n-2]) {r=3*d[n-2]}; m[n-1]=r
        return m
    }
}
