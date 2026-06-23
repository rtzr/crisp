import Foundation

/// Builds a small, reproducible evaluation corpus from real in-repo speech + noise assets,
/// covering the degradation categories of PRD 8.1 (noise at several SNRs, reverb, clipping,
/// low bandwidth, level extremes, mains hum). No downloads — deterministic from the sources.
///
/// The signal ops live here (not just in the CLI) so tests can build a corpus directly.
public enum TestCorpus {
    public struct Entry: Sendable {
        public let name: String       // file name (without dir)
        public let category: String
        public let snrDb: String      // "" if N/A
        public let reference: String  // clean reference file name for SI-SDR, or ""
    }

    /// Generate the corpus into `outDir` from a clean speech file + a noise file.
    /// Returns manifest entries. Writes each entry as a 48 kHz mono WAV plus `manifest.csv`.
    @discardableResult
    public static func generate(speechURL: URL, noiseURL: URL, outDir: URL) throws -> [Entry] {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let sr = Float(AudioIO.sampleRate)
        var speech = try AudioIO.read48kMono(speechURL)
        var noise = try AudioIO.read48kMono(noiseURL)
        guard !speech.isEmpty, !noise.isEmpty else { throw AudioIO.IOError.readFailed("empty source") }
        // Normalize the clean reference to a consistent -3 dBFS peak headroom.
        normalizePeak(&speech, toDb: -3)
        noise = tile(noise, toCount: speech.count)

        var entries: [Entry] = []
        func emit(_ samples: [Float], _ name: String, _ category: String, snr: String = "", ref: String = "clean.wav") throws {
            try AudioIO.writeWav(samples, to: outDir.appendingPathComponent(name))
            entries.append(Entry(name: name, category: category, snrDb: snr, reference: ref))
        }

        try emit(speech, "clean.wav", "clean", ref: "clean.wav")

        for snr in [0, 5, 10, 20] {
            try emit(mix(speech, noise, snrDb: Float(snr)), "noisy_snr\(snr).wav", "noisy", snr: "\(snr)")
        }

        let rev = reverb(speech, sampleRate: sr, rt60: 0.6)
        try emit(rev, "reverb.wav", "reverb")
        try emit(mix(rev, noise, snrDb: 5), "reverb_noisy_snr5.wav", "reverb+noise", snr: "5")

        try emit(hardClip(speech, threshold: 0.4), "clipped.wav", "clipping")

        try emit(lowpass(speech, cutoff: 4000, sampleRate: sr), "lowband_8k.wav", "bandlimit")
        try emit(lowpass(speech, cutoff: 8000, sampleRate: sr), "lowband_16k.wav", "bandlimit")

        try emit(gain(speech, db: -22), "quiet.wav", "level")
        try emit(mix(addHum(speech, sampleRate: sr, freq: 60, level: 0.05), noise, snrDb: 15),
                 "hum_snr15.wav", "hum", snr: "15")

        // Manifest CSV.
        var csv = "file,category,snr_db,reference\n"
        for e in entries { csv += "\(e.name),\(e.category),\(e.snrDb),\(e.reference)\n" }
        try csv.write(to: outDir.appendingPathComponent("manifest.csv"), atomically: true, encoding: .utf8)
        return entries
    }

    // MARK: - Signal ops

    static func tile(_ x: [Float], toCount n: Int) -> [Float] {
        guard !x.isEmpty else { return [Float](repeating: 0, count: n) }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = x[i % x.count] }
        return out
    }

    /// Mix `noise` into `signal` at `snrDb` (relative to signal RMS), then guard against clipping.
    public static func mix(_ signal: [Float], _ noise: [Float], snrDb: Float) -> [Float] {
        let sRms = rms(signal), nRms = rms(noise)
        guard sRms > 0, nRms > 0 else { return signal }
        let targetNoiseRms = sRms / pow(10, snrDb / 20)
        let scale = targetNoiseRms / nRms
        var out = [Float](repeating: 0, count: signal.count)
        for i in 0..<signal.count { out[i] = signal[i] + noise[i % noise.count] * scale }
        normalizePeak(&out, toDb: -1, onlyIfLouder: true)
        return out
    }

    public static func hardClip(_ x: [Float], threshold t: Float) -> [Float] {
        x.map { max(-t, min(t, $0)) }
    }

    public static func gain(_ x: [Float], db: Float) -> [Float] {
        let g = pow(10, db / 20)
        return x.map { $0 * g }
    }

    /// 4th-order Butterworth-ish lowpass (two cascaded biquads) — band-limits for BWE tests.
    public static func lowpass(_ x: [Float], cutoff: Float, sampleRate sr: Float) -> [Float] {
        var b1 = Biquad(), b2 = Biquad()
        // Reuse highpass designer's structure via a lowpass: build from RBJ lowpass coefficients.
        b1.setLowpass(freq: cutoff, q: 0.541, sampleRate: sr)
        b2.setLowpass(freq: cutoff, q: 1.307, sampleRate: sr)
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count { out[i] = b2.process(b1.process(x[i])) }
        return out
    }

    public static func addHum(_ x: [Float], sampleRate sr: Float, freq: Float, level: Float) -> [Float] {
        var out = x
        for i in 0..<out.count {
            let t = Float(i) / sr
            out[i] += level * sin(2 * .pi * freq * t) + level * 0.4 * sin(2 * .pi * freq * 2 * t)
        }
        return out
    }

    /// Schroeder reverberator (4 parallel combs → 2 series allpass). Deterministic; adds a
    /// reverberant tail without needing RIR convolution.
    public static func reverb(_ x: [Float], sampleRate sr: Float, rt60: Float) -> [Float] {
        let combMs: [Float] = [29.7, 37.1, 41.1, 43.7]
        let allpassMs: [Float] = [5.0, 1.7]
        var combs = combMs.map { ms -> (buf: [Float], idx: Int, g: Float) in
            let d = max(1, Int(ms * 0.001 * sr))
            let g = pow(10, -3 * (ms * 0.001) / rt60)   // feedback for target RT60
            return ([Float](repeating: 0, count: d), 0, g)
        }
        var allpasses = allpassMs.map { ms -> (buf: [Float], idx: Int, g: Float) in
            let d = max(1, Int(ms * 0.001 * sr))
            return ([Float](repeating: 0, count: d), 0, 0.7)
        }
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let dry = x[i]
            var wet: Float = 0
            for c in 0..<combs.count {
                let d = combs[c].buf[combs[c].idx]
                wet += d
                combs[c].buf[combs[c].idx] = dry + d * combs[c].g
                combs[c].idx = (combs[c].idx + 1) % combs[c].buf.count
            }
            wet /= Float(combs.count)
            for a in 0..<allpasses.count {
                let bufv = allpasses[a].buf[allpasses[a].idx]
                let input = wet
                let outv = -allpasses[a].g * input + bufv
                allpasses[a].buf[allpasses[a].idx] = input + allpasses[a].g * outv
                allpasses[a].idx = (allpasses[a].idx + 1) % allpasses[a].buf.count
                wet = outv
            }
            out[i] = 0.7 * dry + 0.3 * wet   // mostly-wet reverberant signal
        }
        normalizePeak(&out, toDb: -1, onlyIfLouder: true)
        return out
    }

    // MARK: - Helpers

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var s: Float = 0
        for v in x { s += v * v }
        return (s / Float(x.count)).squareRoot()
    }

    static func normalizePeak(_ x: inout [Float], toDb: Float, onlyIfLouder: Bool = false) {
        var peak: Float = 0
        for v in x { peak = max(peak, abs(v)) }
        guard peak > 0 else { return }
        let target = pow(10, toDb / 20)
        if onlyIfLouder && peak <= target { return }
        let g = target / peak
        for i in 0..<x.count { x[i] *= g }
    }
}
