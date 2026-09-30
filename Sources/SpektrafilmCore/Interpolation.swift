import Foundation

public enum Interpolation {
    public static func linear(x: [Double], y: [Double], at q: Double) -> Double {
        precondition(x.count == y.count && !x.isEmpty)
        if x.count == 1 { return y[0] }
        if q <= x[0] { return y[0] }
        if q >= x[x.count - 1] { return y[y.count - 1] }
        let i = upperBound(x, q) - 1
        let t = (q - x[i]) / max(x[i + 1] - x[i], 1e-15)
        return y[i] * (1 - t) + y[i + 1] * t
    }

    /// Monotonic PCHIP (Fritsch-Carlson style), matching the interpolation family
    /// used by the Rust port for parity-sensitive curve/LUT work.
    public static func pchip(x: [Double], y: [Double], at q: Double) -> Double {
        precondition(x.count == y.count && !x.isEmpty)
        let n = x.count
        if n < 3 { return linear(x: x, y: y, at: q) }
        if q <= x[0] { return y[0] }
        if q >= x[n - 1] { return y[n - 1] }

        var h = [Double](repeating: 0, count: n - 1)
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            h[i] = x[i + 1] - x[i]
            delta[i] = (y[i + 1] - y[i]) / h[i]
        }
        var d = [Double](repeating: 0, count: n)
        d[0] = endpointSlope(h0: h[0], h1: h[1], d0: delta[0], d1: delta[1])
        d[n - 1] = endpointSlope(h0: h[n - 2], h1: h[n - 3], d0: delta[n - 2], d1: delta[n - 3])
        for i in 1..<(n - 1) {
            if delta[i - 1] == 0 || delta[i] == 0 || delta[i - 1].sign != delta[i].sign {
                d[i] = 0
            } else {
                let w1 = 2 * h[i] + h[i - 1]
                let w2 = h[i] + 2 * h[i - 1]
                d[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
            }
        }

        let i = upperBound(x, q) - 1
        let hi = h[i]
        let t = (q - x[i]) / hi
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * y[i] + h10 * hi * d[i] + h01 * y[i + 1] + h11 * hi * d[i + 1]
    }

    private static func endpointSlope(h0: Double, h1: Double, d0: Double, d1: Double) -> Double {
        var d = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
        if d.sign != d0.sign { d = 0 }
        else if d0.sign != d1.sign && abs(d) > abs(3 * d0) { d = 3 * d0 }
        return d
    }

    private static func upperBound(_ a: [Double], _ x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
