import CrispEngine
import Foundation

// Verifies the Voice Enhancer DSP stage and the two-stage pipeline.
//   vetool [model.tar.gz]
// With no args it runs the self-contained DSP checks (no model needed). Given a model path
// it additionally measures the full pipeline RTF (DeepFilter denoise → enhancer).
//
// Checks (mirroring dftool's streaming-determinism guarantee for the suppressor):
//   1. wetMix==0 is bit-identical passthrough (so Off / Noise-only modes don't color audio)
//   2. enhancer output is independent of buffer chunking (state correctness)
//   3. output never exceeds full scale (limiter / clamp safety)
//   4. enhancement measurably changes the signal when active

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never { log("FAIL: \(s)"); exit(1) }

let sr = 48_000.0

/// Deterministic 48 kHz mono test signal: voice-like tones + sibilance band + noise + a
/// loud transient (to exercise the limiter). Fixed-seed LCG → reproducible.
func synth(seconds: Double) -> [Float] {
    let n = Int(seconds * sr)
    var out = [Float](repeating: 0, count: n)
    var seed: UInt64 = 0x1234_5678
    func rnd() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
    }
    for i in 0..<n {
        let t = Double(i) / sr
        var s = 0.30 * sin(2 * .pi * 150 * t)
        s += 0.20 * sin(2 * .pi * 900 * t)
        s += 0.15 * sin(2 * .pi * 3000 * t)
        s += 0.12 * sin(2 * .pi * 6500 * t)   // sibilance band for the de-esser
        out[i] = Float(s) + 0.05 * rnd()
    }
    for i in (n / 2)..<min(n, n / 2 + 200) { out[i] += 1.5 }  // transient → limiter test
    return out
}

func makeEnhancer(active: Bool, strength: EnhanceStrength = .medium, tone: TonePreset = .natural) -> VoiceEnhancer {
    let e = VoiceEnhancer(sampleRate: Float(sr))
    e.prepare(config: AudioProcessingConfig(enhanceStrength: strength, tonePreset: tone))
    e.setActive(active)
    e.snapToTarget()
    return e
}

func processChunked(_ e: VoiceEnhancer, _ x: [Float], sizes: [Int]) -> [Float] {
    var out: [Float] = []; out.reserveCapacity(x.count)
    var i = 0, k = 0
    while i < x.count {
        let n = min(sizes[k % sizes.count], x.count - i)
        out.append(contentsOf: e.process(Array(x[i..<(i + n)])))
        i += n; k += 1
    }
    return out
}

let signal = synth(seconds: 5)
log("test signal: \(signal.count) samples (\(Double(signal.count) / sr)s @ 48k)")

// 1. wetMix == 0 → bit-identical passthrough.
let pass = makeEnhancer(active: false)
let passOut = pass.process(signal)
if passOut != signal { fail("inactive enhancer is not bit-identical passthrough") }
log("PASS 1/4 — inactive enhancer is exact passthrough")

// 2. Chunk independence — aligned vs varied chunk sizes must match bit-for-bit.
let aligned = makeEnhancer(active: true)
let alignedOut = aligned.process(signal)
let chunked = makeEnhancer(active: true)
let chunkedOut = processChunked(chunked, signal, sizes: [137, 480, 53, 911, 256, 1000])
if alignedOut.count != chunkedOut.count { fail("length mismatch \(alignedOut.count) vs \(chunkedOut.count)") }
var maxDiff: Float = 0
for i in 0..<alignedOut.count { maxDiff = max(maxDiff, abs(alignedOut[i] - chunkedOut[i])) }
if maxDiff != 0 { fail("chunked output differs from aligned (maxDiff=\(maxDiff))") }
log("PASS 2/4 — enhancer output is independent of buffer chunking")

// 3. Limiter / clamp safety — output never exceeds full scale.
var peak: Float = 0
for s in alignedOut { peak = max(peak, abs(s)) }
if peak > 1.0001 { fail("output peak \(peak) exceeds full scale") }
log(String(format: "PASS 3/4 — output peak %.4f within full scale (limiter ok)", peak))

// 4. Enhancement actually changes the signal.
var changeEnergy: Double = 0, refEnergy: Double = 0
for i in 0..<signal.count { changeEnergy += Double(alignedOut[i] - signal[i]) * Double(alignedOut[i] - signal[i]); refEnergy += Double(signal[i]) * Double(signal[i]) }
let changeDb = 10 * log10(changeEnergy / max(refEnergy, 1e-12))
if changeEnergy == 0 { fail("active enhancer produced no change") }
log(String(format: "PASS 4/4 — active enhancer changes signal (Δenergy %.1f dB rel.)", changeDb))

// RTF: enhancer alone, and full pipeline if a model is supplied.
func rtf(_ label: String, _ body: () -> Void) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    body()
    let proc = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    let audio = Double(signal.count) / sr
    log(String(format: "RTF %@: proc=%.4fs audio=%.2fs RTF=%.4f", label, proc, audio, proc / audio))
}

let benchEnh = makeEnhancer(active: true)
rtf("enhancer-only") { _ = benchEnh.process(signal) }

if CommandLine.arguments.count >= 2 {
    let modelPath = CommandLine.arguments[1]
    guard let df = DeepFilterSuppressor(modelPath: modelPath) else { fail("model load failed: \(modelPath)") }
    let pipe = PipelineProcessor(suppressor: df)
    pipe.prepare(config: AudioProcessingConfig(mode: .cleanAndEnhance, enhanceStrength: .medium, tonePreset: .natural))
    pipe.snapEnhancerToTarget()
    rtf("clean+enhance pipeline") {
        var i = 0
        while i < signal.count { let n = min(2400, signal.count - i); _ = pipe.process(Array(signal[i..<(i + n)])); i += n }
        _ = pipe.flush()
    }
}

log("ALL CHECKS PASSED")
