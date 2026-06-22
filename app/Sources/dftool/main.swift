import CrispEngine
import Foundation

// Verifies the real DeepFilterSuppressor (the class the app uses).
//   dftool <model.tar.gz> <atten_db> <in.f32> <out.f32> [chunked]
//   in/out: raw 32-bit float, mono, 48 kHz.
// "chunked" feeds varied buffer sizes; its output must match the aligned run bit-for-bit,
// proving the streaming carry preserves frame continuity.

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 5, let atten = Float(args[2]) else {
    die("usage: dftool <model.tar.gz> <atten_db> <in.f32> <out.f32> [chunked]", 2)
}
let chunked = args.count >= 6 && args[5] == "chunked"

guard let sup = DeepFilterSuppressor(modelPath: args[1], attenuationLimitDb: atten) else { die("DeepFilterSuppressor init failed") }
FileHandle.standardError.write("model loaded. hop=\(sup.hop)  mode=\(chunked ? "chunked" : "aligned")\n".data(using: .utf8)!)

guard let inData = FileManager.default.contents(atPath: args[3]) else { die("cannot read \(args[3])") }
let samples = inData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

var out: [Float] = []
out.reserveCapacity(samples.count)
let t0 = DispatchTime.now().uptimeNanoseconds
if chunked {
    let sizes = [137, 480, 1000, 53, 911, 256, 480]   // deliberately non-hop-aligned
    var i = 0, k = 0
    while i < samples.count {
        let n = min(sizes[k % sizes.count], samples.count - i)
        out.append(contentsOf: sup.process(Array(samples[i..<(i + n)])))
        i += n; k += 1
    }
} else {
    out = sup.process(samples)
}
let proc = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
let audio = Double(samples.count) / 48000.0
FileHandle.standardError.write(String(format: "in=%d out=%d audio=%.2fs proc=%.3fs RTF=%.4f\n",
    samples.count, out.count, audio, proc, proc / audio).data(using: .utf8)!)

let outData = out.withUnsafeBufferPointer { Data(buffer: $0) }
try? outData.write(to: URL(fileURLWithPath: args[4]))
