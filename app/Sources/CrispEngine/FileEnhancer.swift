import Foundation
import AVFoundation
import AudioToolbox

public enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case wav, m4a
    public var id: String { rawValue }
    public var ext: String { rawValue }
}

public enum FileEnhanceError: LocalizedError {
    case noAudioTrack, modelLoadFailed, readFailed(String), writeFailed(String)
    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "오디오 트랙을 찾을 수 없습니다."
        case .modelLoadFailed: return "모델을 불러올 수 없습니다."
        case .readFailed(let m): return "디코딩 실패: \(m)"
        case .writeFailed(let m): return "저장 실패: \(m)"
        }
    }
}

/// Offline file enhancement (PRD 4.4 / FILE-01..06) with NO ffmpeg / no external process:
///   AVAssetReader (decode+resample+downmix → 48k mono) → DeepFilterSuppressor → AVAudioFile (wav/m4a).
/// Uses the exact same DeepFilterNet model as the real-time engine.
public final class FileEnhancer {
    private var cancelled = false
    public init() {}
    public func cancel() { cancelled = true }

    public func enhance(input: URL,
                        output: URL,
                        format: OutputFormat,
                        lowLatency: Bool = false,
                        attenuationDb: Float = 100,
                        progress: ((Double) -> Void)? = nil) throws {
        cancelled = false
        guard let modelPath = DeepFilterSuppressor.modelPath(lowLatency ? .lowLatency : .full),
              let suppressor = DeepFilterSuppressor(modelPath: modelPath, attenuationLimitDb: attenuationDb)
        else { throw FileEnhanceError.modelLoadFailed }

        // --- Decode → 48 kHz mono Float32 (AVFoundation handles container/codec/resample/downmix) ---
        let asset = AVURLAsset(url: input)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw FileEnhanceError.noAudioTrack }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw FileEnhanceError.readFailed(error.localizedDescription) }
        let readSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1
        ]
        let trackOut = AVAssetReaderTrackOutput(track: track, outputSettings: readSettings)
        trackOut.alwaysCopiesSampleData = false
        reader.add(trackOut)
        guard reader.startReading() else { throw FileEnhanceError.readFailed("reader start") }

        // --- Output file in the processing format (48k mono float), encoded to wav/m4a ---
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

        let totalSeconds = max(CMTimeGetSeconds(asset.duration), 0.001)
        var writtenSamples = 0

        func write(_ samples: [Float]) throws {
            guard !samples.isEmpty else { return }
            guard let buf = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            memcpy(buf.floatChannelData![0], samples, samples.count * MemoryLayout<Float>.size)
            do { try outFile.write(from: buf) } catch { throw FileEnhanceError.writeFailed(error.localizedDescription) }
            writtenSamples += samples.count
            progress?(min(0.99, Double(writtenSamples) / 48_000.0 / totalSeconds))
        }

        while let sb = trackOut.copyNextSampleBuffer() {
            if cancelled { reader.cancelReading(); throw FileEnhanceError.readFailed("취소됨") }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var dataPtr: UnsafeMutablePointer<Int8>? = nil
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr)
            guard let dp = dataPtr, length > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            let chunk = dp.withMemoryRebound(to: Float.self, capacity: count) { Array(UnsafeBufferPointer(start: $0, count: count)) }
            try write(suppressor.process(chunk))
        }
        if reader.status == .failed { throw FileEnhanceError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        try write(suppressor.flush())
        progress?(1.0)
    }
}
