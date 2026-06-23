import CrispEngine
import Foundation

// Objective metrics for a processed file (PRD 8.2). Reference-free always; SI-SDR when a
// clean reference is given.
//   evaltool <file.wav> [reference.wav]
// Prints CSV-friendly: lufs,peak_db,rms_db,si_sdr_db,nonfinite

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let a = CommandLine.arguments
guard a.count >= 2 else { die("usage: evaltool <file.wav> [reference.wav]", 2) }

do {
    let x = try AudioIO.read48kMono(URL(fileURLWithPath: a[1]))
    let lufs = Loudness.integratedLUFS(x, sampleRate: AudioIO.sampleRate)
    let peak = Metrics.peakDb(x)
    let rms = Metrics.rmsDb(x)
    var siSdr = Double.nan
    if a.count >= 3 {
        let ref = try AudioIO.read48kMono(URL(fileURLWithPath: a[2]))
        // Delay-compensated: the denoiser adds latency, so align before scoring.
        siSdr = Metrics.alignedSiSDR(reference: ref, estimate: x)
    }
    let nonFinite = Metrics.hasNonFinite(x)
    // Human line on stderr, machine line on stdout.
    FileHandle.standardError.write(String(format: "LUFS %.1f  peak %.1f dBFS  rms %.1f dBFS  SI-SDR %@  finite=%@\n",
        lufs, peak, rms, siSdr.isNaN ? "n/a" : String(format: "%.1f dB", siSdr), nonFinite ? "NO" : "yes").data(using: .utf8)!)
    print(String(format: "%.2f,%.2f,%.2f,%@,%@",
        lufs, peak, rms, siSdr.isNaN ? "" : String(format: "%.2f", siSdr), nonFinite ? "1" : "0"))
} catch {
    die("eval failed: \(error.localizedDescription)")
}
