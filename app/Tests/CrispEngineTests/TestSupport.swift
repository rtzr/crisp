import Foundation
import XCTest
@testable import CrispEngine

/// Resolves in-repo assets relative to this source file, so tests work regardless of the
/// process working directory (`swift test` CWD is not guaranteed).
enum TestSupport {
    /// .../app/Tests/CrispEngineTests/TestSupport.swift → repo root (up 4 levels).
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CrispEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
    }

    static var speechURL: URL { repoRoot.appendingPathComponent("poc/model/in/speech.wav") }
    static var noiseURL: URL { repoRoot.appendingPathComponent("poc/model/in/noise.wav") }

    static var hasSourceAssets: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: speechURL.path) && fm.fileExists(atPath: noiseURL.path)
    }

    /// Resolve the bundled DeepFilter model, falling back to the dev tree under the repo root.
    static func modelPath() -> String? {
        let candidates = [
            "engine/models/DeepFilterNet3_onnx.tar.gz",
            "poc/model/DeepFilterNet/models/DeepFilterNet3_onnx.tar.gz",
        ]
        for c in candidates {
            let p = repoRoot.appendingPathComponent(c).path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return DeepFilterSuppressor.modelPath(.full)
    }

    static func tempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crisp_test_\(name)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A deterministic synthetic 48 kHz mono signal (tones + sibilance + noise + transient).
    static func synth(seconds: Double) -> [Float] {
        let sr = 48_000.0
        let n = Int(seconds * sr)
        var out = [Float](repeating: 0, count: n)
        var seed: UInt64 = 0xABCD_1234
        func rnd() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
        }
        for i in 0..<n {
            let t = Double(i) / sr
            var s = 0.30 * sin(2 * .pi * 150 * t) + 0.20 * sin(2 * .pi * 900 * t)
            s += 0.15 * sin(2 * .pi * 3000 * t) + 0.12 * sin(2 * .pi * 6500 * t)
            out[i] = Float(s) + 0.05 * rnd()
        }
        for i in (n / 2)..<min(n, n / 2 + 200) { out[i] += 1.5 }
        return out
    }
}
