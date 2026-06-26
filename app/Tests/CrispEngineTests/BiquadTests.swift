import XCTest
@testable import CrispEngine

final class BiquadTests: XCTestCase {
    let sr: Float = 48_000

    private func rms(_ x: [Float]) -> Float {
        var s: Float = 0; for v in x { s += v * v }; return (s / Float(x.count)).squareRoot()
    }
    private func tone(_ hz: Float, _ n: Int = 48_000) -> [Float] {
        (0..<n).map { sin(2 * .pi * hz * Float($0) / sr) }
    }

    func testPeakingZeroGainIsIdentity() {
        var b = Biquad()
        b.setPeaking(freq: 1000, q: 1, gainDb: 0, sampleRate: sr)
        let x = tone(1000)
        var maxDiff: Float = 0
        for v in x { maxDiff = max(maxDiff, abs(b.process(v) - v)) }
        XCTAssertLessThan(maxDiff, 1e-5, "0 dB peaking must be a passthrough")
    }

    func testLowpassAttenuatesHighFrequencies() {
        var b1 = Biquad(), b2 = Biquad()
        b1.setLowpass(freq: 2000, q: 0.707, sampleRate: sr)
        b2.setLowpass(freq: 2000, q: 0.707, sampleRate: sr)
        let high = tone(12_000), low = tone(300)
        let highOut = high.map { b2.process(b1.process($0)) }
        b1 = Biquad(); b2 = Biquad()
        b1.setLowpass(freq: 2000, q: 0.707, sampleRate: sr)
        b2.setLowpass(freq: 2000, q: 0.707, sampleRate: sr)
        let lowOut = low.map { b2.process(b1.process($0)) }
        // Skip the filter's startup transient.
        XCTAssertLessThan(rms(Array(highOut[4800...])), 0.1, "12 kHz must be strongly attenuated by a 2 kHz LPF")
        XCTAssertGreaterThan(rms(Array(lowOut[4800...])), 0.5, "300 Hz must pass a 2 kHz LPF")
    }

    func testHighpassRemovesDC() {
        var b = Biquad()
        b.setHighpass(freq: 80, q: 0.707, sampleRate: sr)
        let dc = [Float](repeating: 0.5, count: 48_000)
        let out = dc.map { b.process($0) }
        let tail = Array(out[24_000...])
        let mean = tail.reduce(0, +) / Float(tail.count)
        XCTAssertLessThan(abs(mean), 0.01, "HPF must remove a DC offset")
    }

    func testEnvelopeFollowerTracksLevel() {
        var env = EnvelopeFollower()
        env.configure(attackMs: 1, releaseMs: 50, sampleRate: sr)
        var last: Float = 0
        for _ in 0..<4800 { last = env.process(0.8) }   // constant 0.8 magnitude
        XCTAssertEqual(last, 0.8, accuracy: 0.02, "envelope should converge to the signal magnitude")
    }
}
