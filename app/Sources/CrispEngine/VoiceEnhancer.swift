import Foundation

/// The Voice Enhancer stage (PRD 4.2 "Realtime: lightweight enhancer + DSP", and the
/// Post-DSP block of PRD 4.1). A zero-latency, identity-preserving DSP chain — *not* a
/// generative model, so the speaker is never altered (PRD 2.3 / 6.2 / explicit exclusions).
///
/// Chain (per sample): high-pass (rumble) → tone EQ → compressor (level uniformity) →
/// de-esser (sibilance) → output limiter (clip safety). The whole chain runs continuously
/// even when `targetWetMix == 0`, so its filter/compressor state stays warm and the
/// dry→wet blend can ramp without a startup transient — this is what makes mode switching
/// click-free (PRD 8.4). At `wetMix == 0` the output is bit-identical to the input.
///
/// This is a swappable stage (PRD 4.5): a neural enhancer (LocalVQE / Resemble) can replace
/// it behind the same `AudioProcessor`/streaming contract without touching the pipeline.
public final class VoiceEnhancer: AudioProcessor {
    private let sampleRate: Float
    private var prepared = false

    // EQ + filters (one set; mono path).
    private var hpf = Biquad()
    private var eqA = Biquad()
    private var eqB = Biquad()
    private var eqC = Biquad()
    private var deEssShelf = Biquad()     // fixed high-shelf cut, blended in dynamically
    private var deEssDetector = Biquad()  // side-chain high-pass

    private var compEnv = EnvelopeFollower()
    private var deEssEnv = EnvelopeFollower()
    private var limiterEnv = EnvelopeFollower()

    // Derived parameters.
    private var compThresholdDb: Float = -24
    private var compRatio: Float = 2
    private var makeupGainLin: Float = 1
    private var deEssThresholdDb: Float = -28
    private var deEssRangeDb: Float = 12
    private var limiterCeilingLin: Float = 0.891  // -1 dBFS

    // Dry→wet blend (ramped to avoid clicks on mode/preset change).
    private var wetMix: Float = 0
    private var targetWetMix: Float = 0
    private var mixStep: Float = 0

    public init(sampleRate: Float = 48_000) {
        self.sampleRate = sampleRate
    }

    public var addedLatencyMs: Double { 0 }  // IIR chain, no lookahead

    /// Whether the enhancer contributes to the output. Setting this ramps the blend.
    public var bypassed: Bool = false {
        didSet { targetWetMix = (bypassed || baseTargetMix == 0) ? 0 : baseTargetMix }
    }
    private var baseTargetMix: Float = 0

    public func prepare(config: AudioProcessingConfig) {
        let intensity = config.enhanceStrength.intensity

        // Rumble / DC: gentle 2nd-order high-pass (PRD 4.2 "60~80 Hz HPF").
        hpf.setHighpass(freq: config.tonePreset == .bright ? 90 : 80, q: 0.707, sampleRate: sampleRate)

        // Tone EQ — three understandable shapes (PRD 3.2). Unused slots are 0 dB (identity).
        // Designers only rewrite coefficients (not delay state), so re-preparing live to
        // change tone/strength does not zero the filters and therefore does not click.
        switch config.tonePreset {
        case .natural:
            eqA.setPeaking(freq: 3000, q: 0.9, gainDb: 2.0 * intensity, sampleRate: sampleRate)
            eqB.setPeaking(freq: 1000, q: 1.0, gainDb: 0, sampleRate: sampleRate)
            eqC.setPeaking(freq: 1000, q: 1.0, gainDb: 0, sampleRate: sampleRate)
        case .warm:
            eqA.setLowShelf(freq: 180, gainDb: 3.0 * intensity, sampleRate: sampleRate)
            eqB.setHighShelf(freq: 9000, gainDb: -2.0 * intensity, sampleRate: sampleRate)
            eqC.setPeaking(freq: 2500, q: 1.2, gainDb: 1.0 * intensity, sampleRate: sampleRate)
        case .bright:
            eqA.setPeaking(freq: 4000, q: 1.0, gainDb: 2.5 * intensity, sampleRate: sampleRate)
            eqB.setHighShelf(freq: 7500, gainDb: 3.0 * intensity, sampleRate: sampleRate)
            eqC.setPeaking(freq: 1000, q: 1.0, gainDb: 0, sampleRate: sampleRate)
        }

        // Compressor — level uniformity (PRD 4.2 "mild compressor"). Conservative defaults.
        compThresholdDb = -24
        compRatio = 1.5 + 1.5 * intensity                    // 1.5:1 … 3:1
        makeupGainLin = pow(10, (2.0 * intensity) / 20)      // up to +2 dB
        compEnv.configure(attackMs: 8, releaseMs: 120, sampleRate: sampleRate)

        // De-esser — dynamic high-shelf cut blended in on sibilance (PRD 4.2 "de-esser").
        let deEssMaxCutDb = -(3 + 5 * intensity)             // up to ~ -8 dB
        deEssShelf.setHighShelf(freq: 5500, gainDb: deEssMaxCutDb, sampleRate: sampleRate)
        deEssDetector.setHighpass(freq: 5000, q: 0.707, sampleRate: sampleRate)
        deEssThresholdDb = -30
        deEssRangeDb = 14
        deEssEnv.configure(attackMs: 1, releaseMs: 60, sampleRate: sampleRate)

        // Output limiter — clip safety at -1 dBFS (PRD 4.2 "output limiter").
        limiterCeilingLin = pow(10, -1.0 / 20)
        limiterEnv.configure(attackMs: 0.5, releaseMs: 50, sampleRate: sampleRate)

        // 40 ms equal-rate dry→wet ramp (PRD 4.2 "30~80 ms crossfade").
        mixStep = 1 / (0.040 * sampleRate)
        prepared = true
    }

    /// Set whether enhancement is active (ramped). Pipeline calls this on mode changes.
    public func setActive(_ active: Bool) {
        baseTargetMix = active ? 1 : 0
        targetWetMix = (bypassed || !active) ? 0 : 1
    }

    /// Jump the blend straight to its target — for offline/file processing where there is
    /// no listener to protect from a transient.
    public func snapToTarget() { wetMix = targetWetMix }

    public func reset() {
        hpf.reset(); eqA.reset(); eqB.reset(); eqC.reset()
        deEssShelf.reset(); deEssDetector.reset()
        compEnv.reset(); deEssEnv.reset(); limiterEnv.reset()
    }

    public func process(_ input: [Float]) -> [Float] {
        guard prepared else { return input }
        var out = [Float](repeating: 0, count: input.count)
        let eps: Float = 1e-7
        for i in 0..<input.count {
            let dry = input[i]

            // Ramp the blend toward target.
            if wetMix < targetWetMix { wetMix = min(targetWetMix, wetMix + mixStep) }
            else if wetMix > targetWetMix { wetMix = max(targetWetMix, wetMix - mixStep) }

            // Always run the chain to keep state warm (even at wetMix 0).
            var x = hpf.process(dry)
            x = eqA.process(x); x = eqB.process(x); x = eqC.process(x)

            // Compressor (downward).
            let env = compEnv.process(x)
            let envDb = 20 * log10(env + eps)
            if envDb > compThresholdDb {
                let grDb = (compThresholdDb - envDb) * (1 - 1 / compRatio)  // ≤ 0
                x *= pow(10, grDb / 20)
            }
            x *= makeupGainLin

            // De-esser: blend a fixed high-shelf cut in proportion to sibilance energy.
            let det = deEssEnv.process(deEssDetector.process(x))
            let detDb = 20 * log10(det + eps)
            let shelved = deEssShelf.process(x)
            if detDb > deEssThresholdDb {
                let a = min(1, (detDb - deEssThresholdDb) / deEssRangeDb)
                x = x * (1 - a) + shelved * a
            }

            // Output limiter (-1 dBFS), then hard safety clamp.
            let pk = limiterEnv.process(x)
            if pk > limiterCeilingLin { x *= limiterCeilingLin / pk }
            x = max(-1, min(1, x))

            out[i] = dry * (1 - wetMix) + x * wetMix
        }
        return out
    }
}
