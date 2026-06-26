import XCTest
@testable import CrispEngine

/// End-to-end tests over the real in-repo corpus + DeepFilter model. Skipped (not failed)
/// when the assets/model produced by `scripts/fetch-deps.sh` aren't present.
final class IntegrationTests: XCTestCase {

    func testCorpusGenerationProducesValidFiles() throws {
        try XCTSkipUnless(TestSupport.hasSourceAssets, "source speech/noise assets not present")
        let outDir = TestSupport.tempDir("corpus")
        let entries = try TestCorpus.generate(speechURL: TestSupport.speechURL,
                                              noiseURL: TestSupport.noiseURL, outDir: outDir)
        XCTAssertGreaterThanOrEqual(entries.count, 10, "corpus should cover PRD 8.1 categories")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("manifest.csv").path))
        for e in entries {
            let samples = try AudioIO.read48kMono(outDir.appendingPathComponent(e.name))
            XCTAssertGreaterThan(samples.count, 0, "\(e.name) should be non-empty")
            XCTAssertFalse(Metrics.hasNonFinite(samples), "\(e.name) must be finite")
            XCTAssertLessThanOrEqual(samples.map { abs($0) }.max() ?? 0, 1.0001, "\(e.name) within full scale")
        }
    }

    func testCorpusSignalOps() {
        let x = TestSupport.synth(seconds: 1)
        let noise = TestSupport.synth(seconds: 0.5)
        // Mix at a target SNR and verify the achieved SNR is in the right ballpark.
        let mixed = TestCorpus.mix(x, noise, snrDb: 10)
        XCTAssertEqual(mixed.count, x.count)
        XCTAssertFalse(Metrics.hasNonFinite(mixed))
        // Clipping bounds the signal.
        let clipped = TestCorpus.hardClip(x, threshold: 0.3)
        XCTAssertLessThanOrEqual(clipped.map { abs($0) }.max() ?? 0, 0.3001)
        // Low-pass reduces high-frequency energy.
        let lp = TestCorpus.lowpass(TestSupport.synth(seconds: 1), cutoff: 1000, sampleRate: 48_000)
        XCTAssertFalse(Metrics.hasNonFinite(lp))
    }

    func testFileEnhancerEndToEndWithModel() throws {
        try XCTSkipUnless(TestSupport.hasSourceAssets, "source assets not present")
        guard TestSupport.modelPath() != nil else { throw XCTSkip("DeepFilter model not present") }
        // FileEnhancer resolves the model relative to CWD; point CWD at the repo root.
        FileManager.default.changeCurrentDirectoryPath(TestSupport.repoRoot.path)

        let outDir = TestSupport.tempDir("enhance")
        let out = outDir.appendingPathComponent("clean_enhance.wav")
        let opts = FileEnhanceOptions(mode: .cleanAndEnhance, quality: .hq,
                                      enhanceStrength: .medium, tonePreset: .natural,
                                      noiseAttenuationDb: 100, loudness: .podcast, format: .wav)
        let report = try FileEnhancer().enhance(input: TestSupport.speechURL, output: out, options: opts)

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let inSamples = try AudioIO.read48kMono(TestSupport.speechURL)
        let outSamples = try AudioIO.read48kMono(out)
        // Duration preserved within ~50 ms (model hop carry/flush).
        XCTAssertEqual(Double(outSamples.count), Double(inSamples.count), accuracy: 48_000 * 0.05)
        XCTAssertFalse(Metrics.hasNonFinite(outSamples))
        XCTAssertLessThanOrEqual(report.outputPeakDb, -1.0 + 0.1, "HQ output must respect the -1 dBFS ceiling")
        XCTAssertTrue(report.outputLUFS.isFinite)
    }

    func testFileEnhancerOffModeNeedsNoModel() throws {
        try XCTSkipUnless(TestSupport.hasSourceAssets, "source assets not present")
        let outDir = TestSupport.tempDir("enhance_off")
        let out = outDir.appendingPathComponent("off.wav")
        let opts = FileEnhanceOptions(mode: .off, quality: .fast, loudness: .none, format: .wav)
        _ = try FileEnhancer().enhance(input: TestSupport.speechURL, output: out, options: opts)
        let outSamples = try AudioIO.read48kMono(out)
        XCTAssertGreaterThan(outSamples.count, 0)
        XCTAssertFalse(Metrics.hasNonFinite(outSamples))
    }
}
