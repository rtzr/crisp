import CrispEngine
import Foundation

// Verifies FileEnhancer (the ffmpeg-free file path the app uses).
//   single: filetool <input> <output> <wav|m4a> [ll]
//   batch:  filetool batch <input> <outdir> <wav|m4a> <csv-atten-levels>   e.g. 6,24,100

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let a = CommandLine.arguments
do {
    if a.count >= 6 && a[1] == "batch", let fmt = OutputFormat(rawValue: a[4]) {
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
        die("usage:\n  filetool <in> <out> <wav|m4a> [ll]\n  filetool batch <in> <outdir> <wav|m4a> <csv-levels>", 2)
    }
} catch {
    die("\n\(error.localizedDescription)")
}
