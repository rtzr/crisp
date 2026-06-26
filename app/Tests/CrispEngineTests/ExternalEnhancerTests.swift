import XCTest
@testable import CrispEngine

/// Verifies the external-model integration seam end-to-end using `cp` as a stand-in "model"
/// (passthrough). Proves the plumbing — decode → external process → HQ post-DSP (loudness +
/// true-peak) → write — works; a real model (Resemble/ClearerVoice) is just a different command.
final class ExternalEnhancerTests: XCTestCase {

    func testExternalSeamWithPassthroughCommand() throws {
        try XCTSkipUnless(TestSupport.hasSourceAssets, "source assets not present")
        let outDir = TestSupport.tempDir("ext")
        let out = outDir.appendingPathComponent("ext_out.wav")
        // Stand-in "model": copy input → output (env resolves `cp` on PATH).
        let model = ExternalEnhancer(name: "passthrough", command: ["cp", "{in}", "{out}"])
        let opts = FileEnhanceOptions(mode: .cleanAndEnhance, quality: .hq, loudness: .podcast, format: .wav)
        let report = try FileEnhancer().enhanceExternal(input: TestSupport.speechURL, output: out, model: model, options: opts)

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let samples = try AudioIO.read48kMono(out)
        XCTAssertGreaterThan(samples.count, 0)
        XCTAssertFalse(Metrics.hasNonFinite(samples))
        // HQ post-DSP must have applied the −1 dBTP true-peak ceiling even though the "model"
        // was a passthrough.
        XCTAssertLessThanOrEqual(report.outputTruePeakDb, -1.0 + 0.25, "HQ post must enforce −1 dBTP")
        XCTAssertTrue(report.outputLUFS.isFinite)
    }

    func testExternalEnhancerSurfacesFailure() {
        let model = ExternalEnhancer(name: "bogus", command: ["this-binary-does-not-exist-xyz", "{in}", "{out}"])
        let tmp = TestSupport.tempDir("extfail")
        XCTAssertThrowsError(try model.run(input: tmp.appendingPathComponent("a"),
                                           output: tmp.appendingPathComponent("b")),
                             "a missing model binary must throw, not crash")
    }
}
