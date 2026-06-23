import Foundation
import AVFoundation

/// Minimal, dependency-free audio file I/O at the engine's canonical format (48 kHz mono
/// Float). Shared by the test-set generator, the eval CLI, and tests. Uses AVFoundation only
/// (no ffmpeg), matching `FileEnhancer`.
public enum AudioIO {
    public static let sampleRate = 48_000.0

    public enum IOError: LocalizedError {
        case noAudioTrack, readFailed(String), writeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "오디오 트랙 없음"
            case .readFailed(let m): return "읽기 실패: \(m)"
            case .writeFailed(let m): return "쓰기 실패: \(m)"
            }
        }
    }

    /// Decode + resample + downmix any audio/video file to 48 kHz mono Float.
    public static func read48kMono(_ url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw IOError.noAudioTrack }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw IOError.readFailed(error.localizedDescription) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw IOError.readFailed("reader start") }

        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0; var dataPtr: UnsafeMutablePointer<Int8>? = nil
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr)
            guard let dp = dataPtr, length > 0 else { continue }
            let count = length / MemoryLayout<Float>.size
            dp.withMemoryRebound(to: Float.self, capacity: count) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: count)) }
        }
        if reader.status == .failed { throw IOError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        return samples
    }

    /// Write 48 kHz mono Float samples to a 16-bit PCM WAV file.
    public static func writeWav(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file: AVAudioFile
        do { file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw IOError.writeFailed(error.localizedDescription) }
        let chunk = 48_000
        var i = 0
        while i < samples.count {
            let n = min(chunk, samples.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { _ = memcpy(buf.floatChannelData![0], $0.baseAddress! + i, n * MemoryLayout<Float>.size) }
            do { try file.write(from: buf) } catch { throw IOError.writeFailed(error.localizedDescription) }
            i += n
        }
    }
}
