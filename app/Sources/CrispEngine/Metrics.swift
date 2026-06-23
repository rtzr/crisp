import Foundation

/// Reference-free and reference-based objective audio metrics (PRD 8.2). Dependency-free
/// (no PESQ/STOI libs); these are the metrics computable in-tree. DNSMOS/PESQ remain
/// optional external steps documented in the test report.
public enum Metrics {
    public static func rmsDb(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return -.infinity }
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        let rms = (sum / Double(x.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }

    public static func peakDb(_ x: [Float]) -> Double {
        var p: Float = 0
        for v in x { p = max(p, abs(v)) }
        return p > 0 ? 20 * log10(Double(p)) : -.infinity
    }

    /// Scale-invariant SDR (Le Roux et al.) between a clean reference and an estimate, in dB.
    /// Higher is better. Scale-invariant but not EQ-invariant, so a coloring enhancer scores
    /// lower than pure denoise — informative, not a defect.
    public static func siSDR(reference: [Float], estimate: [Float]) -> Double {
        let n = min(reference.count, estimate.count)
        guard n > 0 else { return -.infinity }
        var dotRE = 0.0, dotRR = 0.0
        for i in 0..<n { dotRE += Double(reference[i]) * Double(estimate[i]); dotRR += Double(reference[i]) * Double(reference[i]) }
        guard dotRR > 0 else { return -.infinity }
        let scale = dotRE / dotRR
        var targetEnergy = 0.0, noiseEnergy = 0.0
        for i in 0..<n {
            let t = scale * Double(reference[i])
            let e = Double(estimate[i]) - t
            targetEnergy += t * t
            noiseEnergy += e * e
        }
        guard noiseEnergy > 0, targetEnergy > 0 else { return .infinity }
        return 10 * log10(targetEnergy / noiseEnergy)
    }

    /// Best integer lag (samples) of `estimate` relative to `reference`, found by maximizing
    /// cross-correlation over a central window. Needed because neural denoisers add a
    /// processing delay, and SI-SDR is delay-sensitive.
    public static func estimateLag(reference: [Float], estimate: [Float], maxLag: Int, window: Int) -> Int {
        let n = min(reference.count, estimate.count)
        guard n > 0 else { return 0 }
        let w = min(window, n)
        let start = (n - w) / 2
        var bestLag = 0, bestCorr = -Double.greatestFiniteMagnitude
        for lag in -maxLag...maxLag {
            var corr = 0.0
            var i = start
            let end = start + w
            while i < end {
                let j = i + lag
                if j >= 0 && j < estimate.count { corr += Double(reference[i]) * Double(estimate[j]) }
                i += 1
            }
            if corr > bestCorr { bestCorr = corr; bestLag = lag }
        }
        return bestLag
    }

    /// Delay-compensated SI-SDR: aligns `estimate` to `reference` first (so a denoiser's
    /// processing latency doesn't collapse the score), then computes SI-SDR on the overlap.
    public static func alignedSiSDR(reference: [Float], estimate: [Float],
                                    maxLagSamples: Int = 1500, window: Int = 24_000) -> Double {
        let lag = estimateLag(reference: reference, estimate: estimate, maxLag: maxLagSamples, window: window)
        let shifted: [Float]
        if lag > 0 { shifted = Array(estimate[lag...]) }
        else if lag < 0 { shifted = Array(repeating: 0, count: -lag) + estimate }
        else { shifted = estimate }
        return siSDR(reference: reference, estimate: shifted)
    }

    /// True if any sample is NaN or infinite — a hard failure for an audio processor.
    public static func hasNonFinite(_ x: [Float]) -> Bool {
        for v in x where !v.isFinite { return true }
        return false
    }
}
