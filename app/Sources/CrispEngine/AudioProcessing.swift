import Foundation

/// Processing mode the user selects (PRD 2.2 / 4.5 / FR-RT-002).
///
/// The pipeline is a two-stage graph — a *Noise Cancellation* stage (DeepFilter) and a
/// *Voice Enhancer* stage (DSP) — and the mode just selects which stages are active.
/// Both stages stay structurally in the signal path at all times (the enhancer blends
/// dry→wet, the suppressor runs at a varying attenuation) so switching modes never
/// re-routes the stream and therefore never clicks (PRD 8.4 "모드 전환 시 pop/click 없음").
public enum ProcessingMode: String, CaseIterable, Identifiable, Sendable {
    case off                 // passthrough — A/B baseline, low power
    case noiseCancellation   // denoise only (existing MVP)
    case voiceEnhancer       // light denoise + DSP enhancement
    case cleanAndEnhance     // full denoise → DSP enhancement (recommended default)

    public var id: String { rawValue }

    /// Whether the Voice Enhancer (DSP) stage contributes to the output.
    public var usesEnhancer: Bool {
        self == .voiceEnhancer || self == .cleanAndEnhance
    }

    /// How hard the Noise Cancellation stage works, relative to the user's strength.
    /// `voiceEnhancer` keeps denoise gentle (PRD 2.2: "잡음 제거는 약하게 적용").
    public enum DenoisePolicy { case none, light, full }
    public var denoisePolicy: DenoisePolicy {
        switch self {
        case .off:               return .none
        case .noiseCancellation: return .full
        case .voiceEnhancer:     return .light
        case .cleanAndEnhance:   return .full
        }
    }
}

/// Enhancement intensity (PRD 3.2 / FR-RT-003). Defaults stay conservative — High can
/// introduce artifacts and is never the default (PRD 6.2 / 8.3).
public enum EnhanceStrength: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    public var id: String { rawValue }

    /// 0…1 scalar that scales every enhancer band/amount.
    public var intensity: Float {
        switch self {
        case .low:    return 0.45
        case .medium: return 0.75
        case .high:   return 1.0
        }
    }
}

/// Tone shaping (PRD 3.2). Three understandable options, not a parametric EQ.
public enum TonePreset: String, CaseIterable, Identifiable, Sendable {
    case natural   // gentle presence lift, true-to-source
    case warm      // body boost, softened highs — close, podcast-like
    case bright    // air/presence boost — clarity on dull mics
    public var id: String { rawValue }
}

/// Light denoise attenuation limit (dB) used by `voiceEnhancer` mode.
public let lightDenoiseAttenuationDb: Float = 10

/// Full pipeline configuration (PRD 4.5 `AudioProcessingConfig`). Carries everything the
/// stage graph needs; the app maps its own UI enums onto this.
public struct AudioProcessingConfig: Sendable {
    public var mode: ProcessingMode
    public var sampleRate: Int
    public var noiseAttenuationDb: Float   // user-chosen Noise Cancellation strength
    public var enhanceStrength: EnhanceStrength
    public var tonePreset: TonePreset
    public var outputGainDb: Float
    public var modelId: String

    public init(mode: ProcessingMode = .cleanAndEnhance,
                sampleRate: Int = 48_000,
                noiseAttenuationDb: Float = 100,
                enhanceStrength: EnhanceStrength = .medium,
                tonePreset: TonePreset = .natural,
                outputGainDb: Float = 0,
                modelId: String = "") {
        self.mode = mode
        self.sampleRate = sampleRate
        self.noiseAttenuationDb = noiseAttenuationDb
        self.enhanceStrength = enhanceStrength
        self.tonePreset = tonePreset
        self.outputGainDb = outputGainDb
        self.modelId = modelId
    }

    /// Attenuation the Noise Cancellation stage should run at for this mode.
    public var effectiveDenoiseDb: Float {
        switch mode.denoisePolicy {
        case .none:  return 0
        case .light: return min(noiseAttenuationDb, lightDenoiseAttenuationDb)
        case .full:  return noiseAttenuationDb
        }
    }
}

/// Streaming audio-processing seam (PRD 4.5 `AudioProcessor`). Mirrors `NoiseSuppressor`'s
/// any-buffer-size contract: feed mono `sampleRate` Float samples, receive processed
/// samples for the work that is ready (a stage may carry a remainder internally).
public protocol AudioProcessor: AnyObject {
    func prepare(config: AudioProcessingConfig)
    func process(_ input: [Float]) -> [Float]
    func reset()
    /// Best-effort added latency of this processor, in milliseconds (PRD 6.1 / SET-02).
    var addedLatencyMs: Double { get }
}
