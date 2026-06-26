import XCTest
@testable import CrispEngine

final class PipelineTests: XCTestCase {
    /// Pipeline driven by a PassthroughSuppressor isolates the routing/enhancer behavior
    /// (no model needed). The suppressor is then 1:1, so lengths are exact.
    private func pipeline(mode: ProcessingMode) -> PipelineProcessor {
        let p = PipelineProcessor(suppressor: PassthroughSuppressor())
        p.prepare(config: AudioProcessingConfig(mode: mode))
        p.snapEnhancerToTarget()
        return p
    }

    func testOffModeIsPassthrough() {
        let x = TestSupport.synth(seconds: 1)
        let out = pipeline(mode: .off).process(x)
        XCTAssertEqual(out, x, "Off mode (passthrough suppressor + inactive enhancer) must be bit-identical")
    }

    func testNoiseCancellationModeDoesNotColor() {
        // PassthroughSuppressor + inactive enhancer → output equals input (enhancer wetMix 0).
        let x = TestSupport.synth(seconds: 1)
        let out = pipeline(mode: .noiseCancellation).process(x)
        XCTAssertEqual(out, x, "Noise mode must not apply enhancer coloring")
    }

    func testCleanAndEnhanceChangesSignalAndPreservesLength() {
        let x = TestSupport.synth(seconds: 1)
        let out = pipeline(mode: .cleanAndEnhance).process(x)
        XCTAssertEqual(out.count, x.count, "1:1 length with passthrough suppressor")
        var diff = 0.0; for i in 0..<x.count { diff += Double(out[i] - x[i]) * Double(out[i] - x[i]) }
        XCTAssertGreaterThan(diff, 0, "enhancer must change the signal in Clean+Enhance")
        XCTAssertFalse(Metrics.hasNonFinite(out))
    }

    func testLiveModeSwitchStaysFinite() {
        let p = pipeline(mode: .cleanAndEnhance)
        _ = p.process(TestSupport.synth(seconds: 0.3))
        for mode in [ProcessingMode.off, .noiseCancellation, .voiceEnhancer, .cleanAndEnhance] {
            p.update(config: AudioProcessingConfig(mode: mode))
            let out = p.process(TestSupport.synth(seconds: 0.3))
            XCTAssertFalse(Metrics.hasNonFinite(out), "[\(mode)] live switch must stay finite")
        }
    }
}
