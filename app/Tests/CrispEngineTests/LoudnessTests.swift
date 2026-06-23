import XCTest
@testable import CrispEngine

final class LoudnessTests: XCTestCase {
    let sr = 48_000.0
    private func sine(_ hz: Double, amp: Float, seconds: Double = 3) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { amp * Float(sin(2 * .pi * hz * Double($0) / sr)) }
    }

    func testSilenceIsNegativeInfinity() {
        let lufs = Loudness.integratedLUFS([Float](repeating: 0, count: 96_000), sampleRate: sr)
        XCTAssertFalse(lufs.isFinite, "silence should measure -inf LUFS")
    }

    func testLouderSignalMeasuresHigher() {
        let quiet = Loudness.integratedLUFS(sine(1000, amp: 0.05), sampleRate: sr)
        let loud = Loudness.integratedLUFS(sine(1000, amp: 0.5), sampleRate: sr)
        XCTAssertGreaterThan(loud, quiet)
        XCTAssertEqual(loud - quiet, 20, accuracy: 0.5, "10× amplitude ≈ +20 LU (loudness is linear in gain)")
    }

    func testNormalizeHitsTargetWhenNotPeakLimited() {
        var x = sine(440, amp: 0.4)
        let target = -30.0   // attenuating, so the -1 dBFS peak ceiling never binds
        let r = Loudness.normalize(&x, toLUFS: target, sampleRate: sr)
        XCTAssertTrue(r.measuredLUFS.isFinite)
        let after = Loudness.integratedLUFS(x, sampleRate: sr)
        XCTAssertEqual(after, target, accuracy: 0.5, "normalized loudness should reach the target")
    }

    func testNormalizeRespectsPeakCeiling() {
        var x = sine(440, amp: 0.5)
        // Ask for a very loud target; the -1 dBFS ceiling must cap the gain.
        Loudness.normalize(&x, toLUFS: 0, sampleRate: sr, ceilingDb: -1.0)
        let peak = x.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(Double(peak), pow(10, -1.0 / 20) + 0.01, "peak must not exceed the ceiling")
    }
}
