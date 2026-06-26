import CrispEngine
import Foundation

// Builds the evaluation corpus (PRD 8.1) from in-repo speech + noise assets.
//   maketestset [outDir] [speechWav] [noiseWav]
// Defaults: out = test/corpus, speech = poc/model/in/speech.wav, noise = poc/model/in/noise.wav

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let a = CommandLine.arguments
let outDir = URL(fileURLWithPath: a.count >= 2 ? a[1] : "test/corpus")
let speech = URL(fileURLWithPath: a.count >= 3 ? a[2] : "poc/model/in/speech.wav")
let noise = URL(fileURLWithPath: a.count >= 4 ? a[3] : "poc/model/in/noise.wav")

guard FileManager.default.fileExists(atPath: speech.path) else { die("speech not found: \(speech.path)\n(run scripts/fetch-deps.sh first, or pass a path)") }
guard FileManager.default.fileExists(atPath: noise.path) else { die("noise not found: \(noise.path)") }

do {
    let entries = try TestCorpus.generate(speechURL: speech, noiseURL: noise, outDir: outDir)
    for e in entries {
        FileHandle.standardError.write("  \(e.name)  [\(e.category)\(e.snrDb.isEmpty ? "" : " SNR \(e.snrDb)dB")]\n".data(using: .utf8)!)
    }
    print("\(entries.count) files → \(outDir.path)")
    print("manifest: \(outDir.appendingPathComponent("manifest.csv").path)")
} catch {
    die("corpus generation failed: \(error.localizedDescription)")
}
