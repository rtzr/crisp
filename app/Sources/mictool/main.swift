import CrispEngine
import Foundation

// End-to-end §8 driver: stream a file through the model → VirtualMicOutput (AUHAL) →
// Crisp virtual device. A separate recorder captures the device's input stream; if the
// recording carries the (denoised) audio, the model→virtual-mic→reader path works.
//
//   mictool <in.f32 (48k mono)> [raw|denoise] [sustainSeconds]
// With sustainSeconds, the audio is looped continuously so a recorder can overlap reliably.

func die(_ m: String, _ c: Int32 = 1) -> Never { FileHandle.standardError.write((m+"\n").data(using:.utf8)!); exit(c) }

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: mictool <in.f32> [raw|denoise] [seconds]", 2) }
let denoise = args.count >= 3 && args[2] == "denoise"

guard let crisp = CoreAudioDevices.deviceID(forUID: CoreAudioDevices.crispVirtualUID) else {
    die("Crisp virtual device not found — install the driver first")
}
guard let data = FileManager.default.contents(atPath: args[1]) else { die("cannot read \(args[1])") }
var samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

if denoise, let mp = DeepFilterSuppressor.modelPath(.full), let sup = DeepFilterSuppressor(modelPath: mp, attenuationLimitDb: 100) {
    var out = sup.process(samples); out.append(contentsOf: sup.flush()); samples = out
    FileHandle.standardError.write("denoised \(samples.count) samples\n".data(using:.utf8)!)
}

let sustain: Double = args.count >= 4 ? (Double(args[3]) ?? 0) : 0

let out = VirtualMicOutput(ringCapacityFrames: samples.count + 96_000)
do { try out.start(deviceID: crisp) } catch { die("VirtualMicOutput start failed: \(error.localizedDescription)") }

func pushAll() { samples.withUnsafeBufferPointer { out.pushMono($0.baseAddress!, count: $0.count) } }
pushAll()
FileHandle.standardError.write("pushed \(samples.count) samples (\(String(format: "%.2f", Double(samples.count)/48000.0))s) to Crisp device \(crisp), sustain=\(sustain)s\n".data(using:.utf8)!)

if sustain > 0 {
    // Keep continuous audio on the virtual mic: refill the ring when it runs low.
    let end = Date().addingTimeInterval(sustain)
    while Date() < end {
        if out.bufferedFrames < 24_000 { pushAll() }   // refill below ~0.5s
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
} else {
    let deadline = Date().addingTimeInterval(Double(samples.count)/48000.0 + 1.0)
    while Date() < deadline && out.bufferedFrames > 0 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}
out.stop()
FileHandle.standardError.write("done\n".data(using:.utf8)!)
