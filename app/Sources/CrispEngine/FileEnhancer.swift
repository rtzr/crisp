import Foundation
import AVFoundation
import AudioToolbox

public enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case wav, m4a
    public var id: String { rawValue }
    public var ext: String { rawValue }
}

/// File processing quality (PRD FR-FILE-002). Fast = denoise/DSP only; HQ adds loudness
/// normalization + peak limiting (and is where a heavier offline model would slot in).
public enum FileQuality: String, CaseIterable, Identifiable, Sendable {
    case fast, hq
    public var id: String { rawValue }
}

/// Everything the file HQ pipeline needs (PRD 4.3 / 5.2).
public struct FileEnhanceOptions: Sendable {
    public var mode: ProcessingMode
    public var quality: FileQuality
    public var enhanceStrength: EnhanceStrength
    public var tonePreset: TonePreset
    public var noiseAttenuationDb: Float
    public var loudness: LoudnessTarget
    public var format: OutputFormat
    public var lowLatencyModel: Bool
    /// Process only the first N seconds (PRD FR-FILE-003 preview). nil = whole file.
    public var previewSeconds: Double?

    public init(mode: ProcessingMode = .cleanAndEnhance,
                quality: FileQuality = .hq,
                enhanceStrength: EnhanceStrength = .medium,
                tonePreset: TonePreset = .natural,
                noiseAttenuationDb: Float = 100,
                loudness: LoudnessTarget = .podcast,
                format: OutputFormat = .wav,
                lowLatencyModel: Bool = false,
                previewSeconds: Double? = nil) {
        self.mode = mode
        self.quality = quality
        self.enhanceStrength = enhanceStrength
        self.tonePreset = tonePreset
        self.noiseAttenuationDb = noiseAttenuationDb
        self.loudness = loudness
        self.format = format
        self.lowLatencyModel = lowLatencyModel
        self.previewSeconds = previewSeconds
    }
}

/// Result of a file enhance run — surfaced to the UI for the before/after report (PRD FR-FILE-006).
public struct FileEnhanceReport: Sendable {
    public let output: URL
    public let inputPeakDb: Double
    public let outputPeakDb: Double
    public let outputLUFS: Double
    public let loudnessGainDb: Double
}

public enum FileEnhanceError: LocalizedError {
    case noAudioTrack, modelLoadFailed, readFailed(String), writeFailed(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "오디오 트랙을 찾을 수 없습니다."
        case .modelLoadFailed: return "모델을 불러올 수 없습니다."
        case .readFailed(let m): return "디코딩 실패: \(m)"
        case .writeFailed(let m): return "저장 실패: \(m)"
        case .cancelled: return "취소되었습니다."
        }
    }
}

/// Offline file enhancement (PRD 4.4) with NO ffmpeg / no external process:
///   AVAssetReader (decode+resample+downmix → 48k mono) → DeepFilterSuppressor → AVAudioFile (wav/m4a).
/// Batch mode decodes once and runs the model at several attenuation levels.
public final class FileEnhancer {
    private var cancelled = false
    public init() {}
    public func cancel() { cancelled = true }

    /// Single output at one attenuation level (dB; 0 = bypass … 100 = full).
    public func enhance(input: URL,
                        output: URL,
                        format: OutputFormat,
                        lowLatency: Bool = false,
                        attenuationDb: Float = 100,
                        progress: ((Double) -> Void)? = nil) throws {
        cancelled = false
        let samples = try decodeTo48kMono(input)
        try suppressAndWrite(samples, to: output, format: format, lowLatency: lowLatency,
                             attenuationDb: attenuationDb, progress: progress)
    }

    /// Batch: one output per attenuation level, input decoded once.
    /// Files are written as `<baseName>_atten<NN>dB.<ext>`. `progress` reports (0...1, currentLevel).
    @discardableResult
    public func enhanceBatch(input: URL,
                             outputDirectory: URL,
                             baseName: String,
                             format: OutputFormat,
                             lowLatency: Bool = false,
                             attenuationLevels: [Float],
                             progress: ((Double, Float) -> Void)? = nil) throws -> [URL] {
        cancelled = false
        guard !attenuationLevels.isEmpty else { return [] }
        let samples = try decodeTo48kMono(input)
        let n = attenuationLevels.count
        var outputs: [URL] = []
        for (i, atten) in attenuationLevels.enumerated() {
            if cancelled { throw FileEnhanceError.cancelled }
            let url = outputDirectory.appendingPathComponent("\(baseName)_atten\(Int(atten))dB.\(format.ext)")
            try suppressAndWrite(samples, to: url, format: format, lowLatency: lowLatency, attenuationDb: atten) { p in
                progress?((Double(i) + p) / Double(n), atten)
            }
            outputs.append(url)
        }
        return outputs
    }

    // MARK: - Voice Enhancer pipeline (PRD 4.3 / 5.2)

    /// Full file pipeline: decode → (denoise) → (Voice Enhancer DSP) → (HQ loudness/peak) → write.
    /// Honors `options.previewSeconds` to render a short before/after sample (FR-FILE-003).
    @discardableResult
    public func enhance(input: URL,
                        output: URL,
                        options: FileEnhanceOptions,
                        progress: ((Double) -> Void)? = nil) throws -> FileEnhanceReport {
        cancelled = false
        var samples = try decodeTo48kMono(input)
        if let secs = options.previewSeconds {
            let limit = Int(secs * 48_000)
            if samples.count > limit { samples = Array(samples[0..<limit]) }
        }
        let inputPeakDb = 20 * log10(Double(peak(samples)) + 1e-9)

        // Build the two-stage pipeline. DeepFilter is the Noise Cancellation stage; if it
        // fails to load we fall back to passthrough so enhance-only / format-convert still work.
        let model: DeepFilterSuppressor.Model = options.lowLatencyModel ? .lowLatency : .full
        let suppressor: NoiseSuppressor
        if let path = DeepFilterSuppressor.modelPath(model),
           let df = DeepFilterSuppressor(modelPath: path) {
            suppressor = df
        } else if options.mode.denoisePolicy != .none {
            throw FileEnhanceError.modelLoadFailed
        } else {
            suppressor = PassthroughSuppressor()
        }
        let config = AudioProcessingConfig(mode: options.mode, sampleRate: 48_000,
                                           noiseAttenuationDb: options.noiseAttenuationDb,
                                           enhanceStrength: options.enhanceStrength,
                                           tonePreset: options.tonePreset,
                                           modelId: model.rawValue)
        let pipeline = PipelineProcessor(suppressor: suppressor)
        pipeline.prepare(config: config)
        pipeline.snapEnhancerToTarget()   // offline: fully wet from sample 0

        // Stream through the pipeline in ~1s blocks, then flush the model tail.
        var processed: [Float] = []
        processed.reserveCapacity(samples.count)
        let block = 48_000
        var i = 0
        while i < samples.count {
            if cancelled { throw FileEnhanceError.cancelled }
            let n = min(block, samples.count - i)
            processed.append(contentsOf: pipeline.process(Array(samples[i..<(i + n)])))
            i += n
            progress?(Double(i) / Double(max(samples.count, 1)) * 0.9)
        }
        processed.append(contentsOf: pipeline.flush())

        // HQ post: loudness normalize to target + peak ceiling (PRD 4.3 steps 6–7).
        var outLUFS = Double.nan, gainDb = 0.0
        if options.quality == .hq, let target = options.loudness.lufs {
            let r = Loudness.normalize(&processed, toLUFS: target, sampleRate: 48_000, ceilingDb: -1.0)
            gainDb = r.gainDb
            outLUFS = Loudness.integratedLUFS(processed, sampleRate: 48_000)
        } else {
            outLUFS = Loudness.integratedLUFS(processed, sampleRate: 48_000)
        }
        progress?(0.95)

        try write(processed, to: output, format: options.format)
        progress?(1.0)
        return FileEnhanceReport(output: output,
                                 inputPeakDb: inputPeakDb,
                                 outputPeakDb: 20 * log10(Double(peak(processed)) + 1e-9),
                                 outputLUFS: outLUFS,
                                 loudnessGainDb: gainDb)
    }

    private func peak(_ s: [Float]) -> Float {
        var p: Float = 0
        for v in s { p = max(p, abs(v)) }
        return p
    }

    private func write(_ samples: [Float], to output: URL, format: OutputFormat) throws {
        let outSettings = Self.outputSettings(format)
        let procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let outFile: AVAudioFile
        do { outFile = try AVAudioFile(forWriting: output, settings: outSettings, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw FileEnhanceError.writeFailed(error.localizedDescription) }
        // Write in chunks so a huge buffer isn't required.
        let chunk = 48_000
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { memcpy(buf.floatChannelData![0], $0.baseAddress! + i, n * MemoryLayout<Float>.size) }
            do { try outFile.write(from: buf) } catch { throw FileEnhanceError.writeFailed(error.localizedDescription) }
            i += n
        }
    }

    private static func outputSettings(_ format: OutputFormat) -> [String: Any] {
        switch format {
        case .wav:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .m4a:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000]
        }
    }

    // MARK: - Decode (once)

    private func decodeTo48kMono(_ input: URL) throws -> [Float] {
        let asset = AVURLAsset(url: input)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw FileEnhanceError.noAudioTrack }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw FileEnhanceError.readFailed(error.localizedDescription) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw FileEnhanceError.readFailed("reader start") }

        var samples: [Float] = []
        samples.reserveCapacity(Int(CMTimeGetSeconds(asset.duration) * 48_000))
        while let sb = out.copyNextSampleBuffer() {
            if cancelled { reader.cancelReading(); throw FileEnhanceError.cancelled }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0; var dataPtr: UnsafeMutablePointer<Int8>? = nil
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr)
            guard let dp = dataPtr, length > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            dp.withMemoryRebound(to: Float.self, capacity: count) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: count)) }
        }
        if reader.status == .failed { throw FileEnhanceError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        return samples
    }

    // MARK: - Suppress + encode (per level)

    private func suppressAndWrite(_ samples: [Float], to output: URL, format: OutputFormat,
                                  lowLatency: Bool, attenuationDb: Float, progress: ((Double) -> Void)?) throws {
        guard let modelPath = DeepFilterSuppressor.modelPath(lowLatency ? .lowLatency : .full),
              let sup = DeepFilterSuppressor(modelPath: modelPath, attenuationLimitDb: attenuationDb)
        else { throw FileEnhanceError.modelLoadFailed }

        let outSettings: [String: Any]
        switch format {
        case .wav:
            outSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .m4a:
            outSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000]
        }
        let procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let outFile: AVAudioFile
        do { outFile = try AVAudioFile(forWriting: output, settings: outSettings, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw FileEnhanceError.writeFailed(error.localizedDescription) }

        func write(_ chunk: [Float]) throws {
            guard !chunk.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: AVAudioFrameCount(chunk.count)) else { return }
            buf.frameLength = AVAudioFrameCount(chunk.count)
            memcpy(buf.floatChannelData![0], chunk, chunk.count * MemoryLayout<Float>.size)
            do { try outFile.write(from: buf) } catch { throw FileEnhanceError.writeFailed(error.localizedDescription) }
        }

        // Stream in ~1s blocks for smooth progress, then flush the model tail.
        let block = 48_000
        var i = 0
        while i < samples.count {
            if cancelled { throw FileEnhanceError.cancelled }
            let n = min(block, samples.count - i)
            try write(sup.process(Array(samples[i..<(i + n)])))
            i += n
            progress?(Double(i) / Double(max(samples.count, 1)) * 0.98)
        }
        try write(sup.flush())
        progress?(1.0)
    }
}
