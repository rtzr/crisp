import Foundation

/// A file-mode "Voice Enhancer" stage backed by an EXTERNAL process (e.g. a PyTorch model
/// CLI like Resemble Enhance or ClearerVoice). This is the integration seam for heavy HQ
/// models that can't be bundled into the Swift/tract runtime (PRD 4.4 "PyTorch helper …
/// 파일 HQ beta까지만 허용"): the model runs out-of-process and exchanges WAV files, then our
/// pipeline applies the post-DSP (loudness + true-peak) and writes the final output.
///
/// The model itself is NOT shipped here — `command` points at whatever the operator has
/// installed (gated on a commercial license, PRD §7.2). With no model installed the file
/// pipeline keeps using the built-in DSP enhancer.
public struct ExternalEnhancer: Sendable {
    public enum ExternalError: LocalizedError {
        case empty, launchFailed(String), nonZeroExit(Int32, String), noOutput
        public var errorDescription: String? {
            switch self {
            case .empty: return "외부 인핸서 명령이 비어 있습니다."
            case .launchFailed(let m): return "외부 인핸서 실행 실패: \(m)"
            case .nonZeroExit(let c, let m): return "외부 인핸서 오류 (코드 \(c)): \(m)"
            case .noOutput: return "외부 인핸서가 출력 파일을 생성하지 않았습니다."
            }
        }
    }

    /// Argv with `{in}` / `{out}` placeholders, e.g. ["resemble-enhance-file", "{in}", "{out}"].
    /// Resolved via `/usr/bin/env` so the binary is found on PATH.
    public let command: [String]
    public let name: String

    public init(name: String, command: [String]) {
        self.name = name
        self.command = command
    }

    /// Run the external model: `input` (48 kHz mono WAV) → `output` WAV. Throws on failure.
    public func run(input: URL, output: URL) throws {
        guard !command.isEmpty else { throw ExternalError.empty }
        let args = command.map {
            $0.replacingOccurrences(of: "{in}", with: input.path)
              .replacingOccurrences(of: "{out}", with: output.path)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do { try proc.run() } catch { throw ExternalError.launchFailed(error.localizedDescription) }
        proc.waitUntilExit()
        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 { throw ExternalError.nonZeroExit(proc.terminationStatus, errText) }
        guard FileManager.default.fileExists(atPath: output.path) else { throw ExternalError.noOutput }
    }
}
