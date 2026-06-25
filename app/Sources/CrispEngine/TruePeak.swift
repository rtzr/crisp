import Foundation

/// True-peak estimation per ITU-R BS.1770-4 (Annex 2): oversample ≥4× and take the peak of
/// the interpolated signal, capturing inter-sample peaks that a raw sample-peak meter misses.
///
/// Implemented as 4× interpolation — the original samples plus three fractional points
/// (¼, ½, ¾) per sample via windowed-sinc fractional-delay FIRs (DC-normalized, so a constant
/// signal never produces a phantom peak). Used to drive the −1 dBTP ceiling in the file
/// pipeline so the output respects true-peak, not just sample-peak.
public enum TruePeak {
    static let taps = 16
    static let half = taps / 2
    /// Fractional-delay kernels for the ¼, ½, ¾ inter-sample positions.
    static let kernels: [[Float]] = [0.25, 0.5, 0.75].map { kernel(frac: Float($0)) }

    private static func kernel(frac: Float) -> [Float] {
        var k = [Float](repeating: 0, count: taps)
        var sum: Float = 0
        for j in 0..<taps {
            let arg = frac + Float(half) - 1 - Float(j)      // sinc center near j = half-1
            let s: Float = arg == 0 ? 1 : sin(.pi * arg) / (.pi * arg)
            let hann: Float = 0.5 - 0.5 * cos(2 * .pi * Float(j) / Float(taps - 1))
            k[j] = s * hann
            sum += k[j]
        }
        if sum != 0 { for j in 0..<taps { k[j] /= sum } }     // unity DC gain
        return k
    }

    /// Linear true-peak (≥ sample peak). Empty → 0.
    public static func truePeak(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var pk: Float = 0
        for i in 0..<x.count {
            pk = max(pk, abs(x[i]))                            // integer-position sample
            // Only interpolate where the full kernel fits — truncating it at the array
            // edges breaks its unity DC gain and would fabricate a phantom overshoot.
            let base = i - half + 1
            guard base >= 0 && base + taps <= x.count else { continue }
            for k in kernels {
                var acc: Float = 0
                for j in 0..<taps { acc += x[base + j] * k[j] }
                pk = max(pk, abs(acc))                         // inter-sample point
            }
        }
        return pk
    }

    public static func truePeakDb(_ x: [Float]) -> Double {
        let pk = truePeak(x)
        return pk > 0 ? 20 * log10(Double(pk)) : -.infinity
    }
}
