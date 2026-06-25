import CrispEngine
import Foundation

// Verifies FileEnhancer (the ffmpeg-free file path the app uses).
//   single:  filetool <input> <output> <wav|m4a> [ll]
//   batch:   filetool batch <input> <outdir> <wav|m4a> <csv-atten-levels>   e.g. 6,24,100
//   enhance: filetool enhance <in> <out> <off|noise|voice|clean> <fast|hq> [natural|warm|bright] [podcast|meeting|none]
//            → full Voice Enhancer pipeline (denoise → DSP enhance → HQ loudness/peak)

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func parseMode(_ s: String) -> ProcessingMode? {
    switch s {
    case "off": return .off
    case "noise": return .noiseCancellation
    case "voice": return .voiceEnhancer
    case "clean": return .cleanAndEnhance
    default: return ProcessingMode(rawValue: s)
    }
}

let a = CommandLine.arguments
do {
    if a.count >= 7 && a[1] == "external", let q = FileQuality(rawValue: a[4]) {
        // filetool external <in> <out> <fast|hq> <podcast|meeting|none> <cmd> [args...]   (cmd uses {in}/{out})
        let loud = LoudnessTarget(rawValue: a[5]) ?? .podcast
        let ext = URL(fileURLWithPath: a[3]).pathExtension.lowercased()
        let fmt = OutputFormat(rawValue: ext) ?? .wav
        let model = ExternalEnhancer(name: "external", command: Array(a[6...]))
        let opts = FileEnhanceOptions(quality: q, loudness: loud, format: fmt)
        let r = try FileEnhancer().enhanceExternal(input: URL(fileURLWithPath: a[2]),
                                                   output: URL(fileURLWithPath: a[3]), model: model, options: opts) { p in
            FileHandle.standardError.write(String(format: "\r%.0f%%   ", p * 100).data(using: .utf8)!)
        }
        FileHandle.standardError.write(String(format: "\nOK  out=%.1f LUFS  truePeak %.1f dBTP  gain %+.1f dB\n",
            r.outputLUFS, r.outputTruePeakDb, r.loudnessGainDb).data(using: .utf8)!)
        print(r.output.path)
    } else if a.count >= 6 && a[1] == "enhance", let mode = parseMode(a[4]), let q = FileQuality(rawValue: a[5]) {
        let tone = a.count >= 7 ? (TonePreset(rawValue: a[6]) ?? .natural) : .natural
        let loud = a.count >= 8 ? (LoudnessTarget(rawValue: a[7]) ?? .podcast) : .podcast
        let ext = URL(fileURLWithPath: a[3]).pathExtension.lowercased()
        let fmt = OutputFormat(rawValue: ext) ?? .wav
        let opts = FileEnhanceOptions(mode: mode, quality: q, enhanceStrength: .medium,
                                      tonePreset: tone, noiseAttenuationDb: 100,
                                      loudness: loud, format: fmt)
        let r = try FileEnhancer().enhance(input: URL(fileURLWithPath: a[2]),
                                           output: URL(fileURLWithPath: a[3]), options: opts) { p in
            FileHandle.standardError.write(String(format: "\r%.0f%%   ", p * 100).data(using: .utf8)!)
        }
        FileHandle.standardError.write(String(format: "\nOK  out=%.1f LUFS  peak %.1f→%.1f dBFS  gain %+.1f dB\n",
            r.outputLUFS, r.inputPeakDb, r.outputPeakDb, r.loudnessGainDb).data(using: .utf8)!)
        print(r.output.path)
    } else if a.count >= 6 && a[1] == "batch", let fmt = OutputFormat(rawValue: a[4]) {
        let levels = a[5].split(separator: ",").compactMap { Float($0) }
        let urls = try FileEnhancer().enhanceBatch(
            input: URL(fileURLWithPath: a[2]),
            outputDirectory: URL(fileURLWithPath: a[3]),
            baseName: URL(fileURLWithPath: a[2]).deletingPathExtension().lastPathComponent,
            format: fmt, attenuationLevels: levels) { p, lvl in
                FileHandle.standardError.write(String(format: "\r%.0f%% (atten %.0fdB)   ", p * 100, lvl).data(using: .utf8)!)
            }
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        urls.forEach { print($0.path) }
    } else if a.count >= 4, let fmt = OutputFormat(rawValue: a[3]) {
        let ll = a.count >= 5 && a[4] == "ll"
        try FileEnhancer().enhance(input: URL(fileURLWithPath: a[1]), output: URL(fileURLWithPath: a[2]),
                                   format: fmt, lowLatency: ll, attenuationDb: 100) { p in
            FileHandle.standardError.write(String(format: "\r%.0f%%", p * 100).data(using: .utf8)!)
        }
        FileHandle.standardError.write("\nOK\n".data(using: .utf8)!)
    } else {
        die("usage:\n  filetool <in> <out> <wav|m4a> [ll]\n  filetool batch <in> <outdir> <wav|m4a> <csv-levels>\n  filetool enhance <in> <out> <off|noise|voice|clean> <fast|hq> [natural|warm|bright] [podcast|meeting|none]\n  filetool external <in> <out> <fast|hq> <podcast|meeting|none> <cmd> [args...]   (cmd uses {in}/{out})", 2)
    }
} catch {
    die("\n\(error.localizedDescription)")
}
