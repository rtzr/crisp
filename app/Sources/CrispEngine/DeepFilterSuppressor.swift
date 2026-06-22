import Foundation
import CDeepFilter

/// DeepFilterNet3 streaming noise suppressor (libDF C-API, pure-Rust tract inference).
///
/// Feeds the model an exact, in-order sequence of `hop`-sized frames regardless of how the
/// caller chunks input — the carry buffer guarantees frame continuity (the model is stateful,
/// so out-of-order or misaligned hops would corrupt the stream). Output for incomplete hops
/// is carried until enough samples arrive.
///
/// Verified: streaming output is bit-identical to aligned processing (see dftool --chunked),
/// and per-hop inference ≈ 0.97 ms vs the 10 ms hop budget.
public final class DeepFilterSuppressor: NoiseSuppressor {
    public enum Model: String {
        case full = "DeepFilterNet3_onnx"        // best quality
        case lowLatency = "DeepFilterNet3_ll_onnx" // SET-01 저지연 모드
    }

    private let st: OpaquePointer
    public let hop: Int
    private var inCarry: [Float] = []
    private var scratchIn: [Float]
    private var scratchOut: [Float]

    public var attenuationLimitDb: Float {
        didSet { df_set_atten_lim(st, bypassed ? 0 : attenuationLimitDb) }
    }
    public var bypassed: Bool {
        didSet { df_set_atten_lim(st, bypassed ? 0 : attenuationLimitDb) }
    }

    /// Resolve a bundled model tar.gz: app Resources/models, then dev-tree fallback.
    public static func modelPath(_ model: Model = .full) -> String? {
        if let url = Bundle.main.url(forResource: model.rawValue, withExtension: "tar.gz", subdirectory: "models") {
            return url.path
        }
        let dev = "engine/models/\(model.rawValue).tar.gz"
        if FileManager.default.fileExists(atPath: dev) { return dev }
        let dev2 = "poc/model/DeepFilterNet/models/\(model.rawValue).tar.gz"
        return FileManager.default.fileExists(atPath: dev2) ? dev2 : nil
    }

    public init?(modelPath: String, attenuationLimitDb: Float = 100, bypassed: Bool = false) {
        guard let state = df_create(modelPath, attenuationLimitDb, nil) else { return nil }
        self.st = state
        self.hop = Int(df_get_frame_length(state))
        self.attenuationLimitDb = attenuationLimitDb
        self.bypassed = bypassed
        self.scratchIn = [Float](repeating: 0, count: hop)
        self.scratchOut = [Float](repeating: 0, count: hop)
        df_set_atten_lim(state, bypassed ? 0 : attenuationLimitDb)
        inCarry.reserveCapacity(hop * 4)
    }

    public func process(_ input: [Float]) -> [Float] {
        inCarry.append(contentsOf: input)
        guard inCarry.count >= hop else { return [] }

        let fullHops = inCarry.count / hop
        var out = [Float](repeating: 0, count: fullHops * hop)
        var consumed = 0
        for h in 0..<fullHops {
            let base = h * hop
            for i in 0..<hop { scratchIn[i] = inCarry[base + i] }
            scratchIn.withUnsafeMutableBufferPointer { ip in
                scratchOut.withUnsafeMutableBufferPointer { op in
                    _ = df_process_frame(st, ip.baseAddress!, op.baseAddress!)
                }
            }
            for i in 0..<hop { out[base + i] = scratchOut[i] }
            consumed += hop
        }
        inCarry.removeFirst(consumed)
        return out
    }

    public func reset() { inCarry.removeAll(keepingCapacity: true) }

    /// Process any remaining carry by zero-padding to a full hop. For offline/file use
    /// (real-time streaming leaves the sub-hop tail carried to avoid clicks).
    public func flush() -> [Float] {
        guard !inCarry.isEmpty else { return [] }
        let valid = inCarry.count
        for i in 0..<hop { scratchIn[i] = i < valid ? inCarry[i] : 0 }
        scratchIn.withUnsafeMutableBufferPointer { ip in
            scratchOut.withUnsafeMutableBufferPointer { op in
                _ = df_process_frame(st, ip.baseAddress!, op.baseAddress!)
            }
        }
        inCarry.removeAll(keepingCapacity: true)
        return Array(scratchOut[0..<valid])
    }

    deinit { df_free(st) }
}
