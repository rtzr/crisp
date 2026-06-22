import CrispEngine
import Foundation

// Verifies FileEnhancer (the ffmpeg-free file path the app uses).
//   filetool <input> <output> <wav|m4a> [ll]

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 4, let fmt = OutputFormat(rawValue: args[3]) else {
    die("usage: filetool <input> <output> <wav|m4a> [ll]", 2)
}
let lowLatency = args.count >= 5 && args[4] == "ll"

do {
    try FileEnhancer().enhance(input: URL(fileURLWithPath: args[1]),
                               output: URL(fileURLWithPath: args[2]),
                               format: fmt,
                               lowLatency: lowLatency,
                               attenuationDb: 100) { p in
        FileHandle.standardError.write(String(format: "\rprogress %.0f%%", p * 100).data(using: .utf8)!)
    }
    FileHandle.standardError.write("\nOK\n".data(using: .utf8)!)
} catch {
    die("\n\(error.localizedDescription)")
}
