import Foundation
import AVFoundation
import AudioToolbox

public enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case wav, m4a
    public var id: String { rawValue }
    public var ext: String { rawValue }
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
