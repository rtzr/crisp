import XCTest
@testable import CrispEngine

final class TruePeakTests: XCTestCase {
    let sr = 48_000.0

    func testConstantHasNoPhantomPeak() {
        // A DC/constant signal has no inter-sample overshoot → true peak ≈ sample peak.
        let x = [Float](repeating: 0.5, count: 2000)
        XCTAssertEqual(Double(TruePeak.truePeak(x)), 0.5, accuracy: 0.01)
    }

    func testTruePeakAtLeastSamplePeak() {
        let x = TestSupport.synth(seconds: 1)
        let sample = x.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(TruePeak.truePeak(x) + 1e-4, sample, "true peak must be ≥ sample peak")
    }

    func testDetectsInterSamplePeak() {
        // A high-frequency tone whose true peak exceeds the sampled maxima between samples.
        // Near Nyquist/3, sampling lands off the crests, so true peak > sample peak.
        let f = 16_000.0
        let n = 4800
        let x = (0..<n).map { 0.9 * Float(sin(2 * .pi * f * Double($0) / sr)) }
        let sample = x.map { abs($0) }.max() ?? 0
        let tp = TruePeak.truePeak(x)
        XCTAssertGreaterThan(tp, sample, "inter-sample peak should exceed the sample peak for a high tone")
        XCTAssertLessThan(Double(tp), 1.1, "but should stay near the true amplitude (0.9), not blow up")
    }

    func testNormalizeRespectsTruePeakCeiling() {
        // Loud high-frequency content → normalize must keep TRUE peak under the ceiling.
        let f = 15_000.0
        var x = (0..<48_000).map { 0.6 * Float(sin(2 * .pi * f * Double($0) / sr)) }
        Loudness.normalize(&x, toLUFS: 0, sampleRate: sr, ceilingDb: -1.0)
        let tpDb = TruePeak.truePeakDb(x)
        XCTAssertLessThanOrEqual(tpDb, -1.0 + 0.25, "true peak must be at/under the −1 dBTP ceiling")
    }
}
