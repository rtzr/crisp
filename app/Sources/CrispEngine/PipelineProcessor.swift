import Foundation

/// The two-stage processing graph (PRD 4.1): Noise Cancellation stage → Voice Enhancer stage.
///
/// Both stages stay structurally in the path for every mode. The mode only changes
/// *parameters* — the suppressor's attenuation (0 dB = passthrough) and whether the
/// enhancer's dry→wet blend ramps up. Because nothing re-routes, switching modes mid-stream
/// can never introduce a sample-count discontinuity or a click (PRD 8.4).
///
/// Streaming contract matches `NoiseSuppressor`: the suppressor emits only complete model
/// hops (carrying a sub-hop remainder), and the enhancer is 1:1, so `process` returns the
/// enhanced version of exactly the hops the suppressor produced this call.
public final class PipelineProcessor: AudioProcessor {
    private let suppressor: NoiseSuppressor
    private let enhancer: VoiceEnhancer
    private var config: AudioProcessingConfig

    /// Inject the Noise Cancellation stage (a real `DeepFilterSuppressor`, or a passthrough
    /// when the model fails to load). The Voice Enhancer stage is owned here.
    public init(suppressor: NoiseSuppressor,
                sampleRate: Float = 48_000,
                config: AudioProcessingConfig = AudioProcessingConfig()) {
        self.suppressor = suppressor
        self.enhancer = VoiceEnhancer(sampleRate: sampleRate)
        self.config = config
    }

    public var addedLatencyMs: Double { enhancer.addedLatencyMs }

    public func prepare(config: AudioProcessingConfig) {
        self.config = config
        enhancer.prepare(config: config)
        applyMode()
    }

    /// Apply a new config live (mode / strength / tone / atten). Safe to call from the UI.
    public func update(config: AudioProcessingConfig) {
        let toneOrStrengthChanged = config.enhanceStrength != self.config.enhanceStrength
            || config.tonePreset != self.config.tonePreset
        self.config = config
        if toneOrStrengthChanged { enhancer.prepare(config: config) }  // preserves filter state
        applyMode()
    }

    private func applyMode() {
        // Noise Cancellation stage: run at the mode's effective attenuation (0 → passthrough).
        let denoiseDb = config.effectiveDenoiseDb
        suppressor.attenuationLimitDb = denoiseDb
        suppressor.bypassed = denoiseDb <= 0
        // Voice Enhancer stage: ramp in/out for the mode.
        enhancer.setActive(config.mode.usesEnhancer)
    }

    public func process(_ input: [Float]) -> [Float] {
        let denoised = suppressor.process(input)     // complete hops (carries remainder)
        return enhancer.process(denoised)            // 1:1
    }

    public func reset() {
        suppressor.reset()
        enhancer.reset()
    }

    /// Drain the suppressor's carried tail through the enhancer (offline/file use only).
    public func flush() -> [Float] {
        enhancer.process(suppressor.flush())
    }

    /// For offline/file use: jump the enhancer blend straight to its target so the very
    /// first samples are already fully processed (no listener to protect from a transient).
    public func snapEnhancerToTarget() { enhancer.snapToTarget() }
}
