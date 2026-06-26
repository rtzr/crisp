import XCTest
@testable import CrispEngine

final class MetricsTests: XCTestCase {
    func testRmsAndPeakOfConstant() {
        let x = [Float](repeating: 0.5, count: 1000)
        XCTAssertEqual(Metrics.rmsDb(x), -6.02, accuracy: 0.05)
        XCTAssertEqual(Metrics.peakDb(x), -6.02, accuracy: 0.05)
    }

    func testSiSDRIdenticalIsVeryHigh() {
        let x = TestSupport.synth(seconds: 1)
        XCTAssertGreaterThan(Metrics.siSDR(reference: x, estimate: x), 100, "identical signals → near-infinite SI-SDR")
    }

    func testSiSDRImprovesWithLessNoise() {
        let ref = TestSupport.synth(seconds: 1)
        var seed: UInt64 = 7
        func noise(_ amp: Float) -> [Float] {
            ref.map { v in seed = seed &* 6364136223846793005 &+ 1; return v + amp * (Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)) }
        }
        let little = Metrics.siSDR(reference: ref, estimate: noise(0.02))
        let lots = Metrics.siSDR(reference: ref, estimate: noise(0.2))
        XCTAssertGreaterThan(little, lots, "less added noise → higher SI-SDR")
    }

    func testAlignedSiSDRRecoversFromDelay() {
        let x = TestSupport.synth(seconds: 1)
        let delayed = [Float](repeating: 0, count: 300) + x   // x delayed by 300 samples
        XCTAssertLessThan(Metrics.siSDR(reference: x, estimate: delayed), 10, "raw SI-SDR collapses under delay")
        XCTAssertGreaterThan(Metrics.alignedSiSDR(reference: x, estimate: delayed, maxLagSamples: 1000, window: 20_000),
                             30, "alignment should recover a pure delay")
    }

    func testHasNonFiniteDetectsNaN() {
        XCTAssertTrue(Metrics.hasNonFinite([0, 1, .nan, 2]))
        XCTAssertTrue(Metrics.hasNonFinite([0, .infinity]))
        XCTAssertFalse(Metrics.hasNonFinite([0, 0.5, -0.5]))
    }
}
