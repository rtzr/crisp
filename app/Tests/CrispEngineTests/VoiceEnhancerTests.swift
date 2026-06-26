import XCTest
@testable import CrispEngine

final class VoiceEnhancerTests: XCTestCase {
    private func make(active: Bool, strength: EnhanceStrength = .medium, tone: TonePreset = .natural) -> VoiceEnhancer {
        let e = VoiceEnhancer(sampleRate: 48_000)
        e.prepare(config: AudioProcessingConfig(enhanceStrength: strength, tonePreset: tone))
        e.setActive(active)
        e.snapToTarget()
        return e
    }

    func testInactiveIsBitIdenticalPassthrough() {
        let e = make(active: false)
        let x = TestSupport.synth(seconds: 2)
        XCTAssertEqual(e.process(x), x, "inactive enhancer must be an exact passthrough (click-free Off/Noise modes)")
    }

    func testChunkIndependence() {
        let x = TestSupport.synth(seconds: 2)
        let aligned = make(active: true).process(x)

        let chunked = make(active: true)
        var out: [Float] = []
        let sizes = [137, 480, 53, 911, 256, 1000]
        var i = 0, k = 0
        while i < x.count {
            let n = min(sizes[k % sizes.count], x.count - i)
            out.append(contentsOf: chunked.process(Array(x[i..<(i + n)])))
            i += n; k += 1
        }
        XCTAssertEqual(aligned.count, out.count)
        var maxDiff: Float = 0
        for j in 0..<aligned.count { maxDiff = max(maxDiff, abs(aligned[j] - out[j])) }
        XCTAssertEqual(maxDiff, 0, "enhancer output must not depend on buffer chunking")
    }

    func testLimiterKeepsPeakWithinFullScale() {
        // Synth already injects a 1.5 transient; the limiter+clamp must contain it.
        for strength in EnhanceStrength.allCases {
            let out = make(active: true, strength: strength).process(TestSupport.synth(seconds: 2))
            let peak = out.map { abs($0) }.max() ?? 0
            XCTAssertLessThanOrEqual(peak, 1.0001, "[\(strength)] output must not exceed full scale")
            XCTAssertFalse(Metrics.hasNonFinite(out), "[\(strength)] output must be finite")
        }
    }

    func testAllTonePresetsAreFiniteAndChangeSignal() {
        let x = TestSupport.synth(seconds: 1)
        for tone in TonePreset.allCases {
            let out = make(active: true, tone: tone).process(x)
            XCTAssertFalse(Metrics.hasNonFinite(out), "[\(tone)] finite")
            var diff = 0.0; for i in 0..<x.count { diff += Double(out[i] - x[i]) * Double(out[i] - x[i]) }
            XCTAssertGreaterThan(diff, 0, "[\(tone)] active enhancer must change the signal")
        }
    }

    func testWetMixRampIsClickFree() {
        // Going inactive→active should ramp the blend, not jump (no large sample-to-sample step).
        let e = VoiceEnhancer(sampleRate: 48_000)
        e.prepare(config: AudioProcessingConfig())
        e.setActive(false); e.snapToTarget()
        _ = e.process(TestSupport.synth(seconds: 0.2))   // warm up
        e.setActive(true)                                 // ramp up (no snap)
        let out = e.process([Float](repeating: 0.2, count: 4800))
        var maxStep: Float = 0
        for i in 1..<out.count { maxStep = max(maxStep, abs(out[i] - out[i - 1])) }
        XCTAssertLessThan(maxStep, 0.05, "blend should ramp; no abrupt jump on activation")
    }
}
