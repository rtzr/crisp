import Foundation

/// Streaming noise-suppression seam. Feed mono 48 kHz Float samples; receive processed
/// samples for the complete hops that are ready (remainder is carried internally).
/// This streaming contract makes the suppressor correct for *any* buffer size — which is
/// what the AVAudioConverter (non-48k mics) produces — and lets it be verified offline by
/// feeding arbitrary chunk sizes and comparing to aligned processing.
public protocol NoiseSuppressor: AnyObject {
    var attenuationLimitDb: Float { get set }
    var bypassed: Bool { get set }
    /// Returns processed samples for complete hops; may be empty while carrying.
    func process(_ input: [Float]) -> [Float]
    /// Drain any carried sub-hop remainder (offline/file use). Streaming callers skip this.
    func flush() -> [Float]
    func reset()
}

/// Identity suppressor (no model). Returns input unchanged.
public final class PassthroughSuppressor: NoiseSuppressor {
    public var attenuationLimitDb: Float = 100
    public var bypassed: Bool = false
    public init() {}
    public func process(_ input: [Float]) -> [Float] { input }
    public func flush() -> [Float] { [] }
    public func reset() {}
}
