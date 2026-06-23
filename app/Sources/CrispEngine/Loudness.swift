import Foundation

/// Loudness targets for the file HQ pipeline (PRD 4.3).
public enum LoudnessTarget: String, CaseIterable, Identifiable, Sendable {
    case podcast   // -16 LUFS
    case meeting   // -18 LUFS
    case none      // leave level untouched
    public var id: String { rawValue }
    public var lufs: Double? {
        switch self {
        case .podcast: return -16
        case .meeting: return -18
        case .none:    return nil
        }
    }
}

/// Integrated-loudness measurement (ITU-R BS.1770 K-weighting + gating) and normalization.
///
/// The K-weighting and gating follow BS.1770; the final "true-peak" stage is approximated by
/// a sample-peak ceiling (no 4× oversampling), which is conservative for speech and keeps
/// the pipeline dependency-free. Documented as such in the test report.
public enum Loudness {
    /// Gated integrated loudness in LUFS (mono). Returns -.infinity for silence.
    public static func integratedLUFS(_ samples: [Float], sampleRate: Double) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        let sr = Float(sampleRate)

        // K-weighting: stage 1 high-shelf (~+4 dB @ 1.5 kHz), stage 2 high-pass (~38 Hz).
        var shelf = Biquad(); shelf.setHighShelf(freq: 1500, gainDb: 4, sampleRate: sr)
        var hp = Biquad(); hp.setHighpass(freq: 38, q: 0.5, sampleRate: sr)
        var weighted = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count { weighted[i] = hp.process(shelf.process(samples[i])) }

        // 400 ms blocks, 100 ms hop (75% overlap).
        let blockLen = Int(0.400 * sampleRate)
        let hop = Int(0.100 * sampleRate)
        guard blockLen > 0, samples.count >= blockLen else {
            let ms = meanSquare(weighted, 0, weighted.count)
            return ms > 0 ? -0.691 + 10 * log10(Double(ms)) : -.infinity
        }
        var blockLoudness: [Double] = []
        var start = 0
        while start + blockLen <= weighted.count {
            let ms = Double(meanSquare(weighted, start, blockLen))
            blockLoudness.append(ms > 0 ? -0.691 + 10 * log10(ms) : -.infinity)
            start += hop
        }

        // Absolute gate at -70 LUFS, then relative gate at (gated mean − 10 LU).
        let absKept = blockLoudness.enumerated().filter { $0.element > -70 }.map { $0.offset }
        guard !absKept.isEmpty else { return -.infinity }
        let relThreshold = gatedMeanLUFS(blockLoudness, absKept) - 10
        let relKept = absKept.filter { blockLoudness[$0] > relThreshold }
        let kept = relKept.isEmpty ? absKept : relKept
        return gatedMeanLUFS(blockLoudness, kept)
    }

    /// Normalize to `targetLUFS`, then bring sample peaks down to `ceilingDb` if needed.
    /// Returns the applied gain (dB) and the measured input loudness.
    @discardableResult
    public static func normalize(_ samples: inout [Float],
                                 toLUFS targetLUFS: Double,
                                 sampleRate: Double,
                                 ceilingDb: Double = -1.0) -> (gainDb: Double, measuredLUFS: Double) {
        let measured = integratedLUFS(samples, sampleRate: sampleRate)
        guard measured.isFinite else { return (0, measured) }
        var gainDb = targetLUFS - measured

        // Don't let the loudness gain push peaks over the ceiling.
        let ceilingLin = Float(pow(10, ceilingDb / 20))
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        if peak > 0 {
            let maxGainLin = ceilingLin / peak
            let maxGainDb = 20 * log10(Double(maxGainLin))
            gainDb = min(gainDb, maxGainDb)
        }
        let gainLin = Float(pow(10, gainDb / 20))
        for i in 0..<samples.count { samples[i] *= gainLin }
        return (gainDb, measured)
    }

    private static func meanSquare(_ x: [Float], _ start: Int, _ count: Int) -> Float {
        var sum: Float = 0
        let end = start + count
        for i in start..<end { sum += x[i] * x[i] }
        return sum / Float(count)
    }

    /// Mean loudness over the kept blocks, computed in the energy domain (per BS.1770).
    private static func gatedMeanLUFS(_ blockLoudness: [Double], _ indices: [Int]) -> Double {
        var energy = 0.0
        for i in indices { energy += pow(10, (blockLoudness[i] + 0.691) / 10) }
        let mean = energy / Double(indices.count)
        return mean > 0 ? -0.691 + 10 * log10(mean) : -.infinity
    }
}
