import Foundation

/// Version info + privacy-safe diagnostic export (PRD SET-03/04).
enum Diagnostics {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    static let modelVersion = "DeepFilterNet3 (tract) + DSP Voice Enhancer"

    /// Rough added latency of the realtime pipeline, in ms (PRD 6.1 / SET-02). The Voice
    /// Enhancer DSP is zero-latency (IIR, no lookahead); the figure is the DeepFilter stage's
    /// algorithmic latency (~10 ms hop, ~20 ms initial buffer for the low-latency model).
    static func estimatedLatencyMs(lowLatency: Bool) -> Double {
        lowLatency ? 20 : 30
    }

    /// Export status/error info only — never voice data (PRD privacy / SET-03).
    @MainActor
    static func export(state: AppState) -> String {
        var lines: [String] = []
        lines.append("Crisp Diagnostics")
        lines.append("app: \(appVersion) (build \(buildNumber))")
        lines.append("model: \(modelVersion)")
        lines.append("os: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("enabled: \(state.isEnabled)  bypassed: \(state.isBypassed)")
        lines.append("mode: \(state.mode.rawValue)")
        lines.append("noiseStrength: \(state.strength.rawValue)  enhanceStrength: \(state.enhanceStrength.rawValue)  tone: \(state.tonePreset.rawValue)")
        lines.append("lowLatencyModel: \(state.lowLatencyMode)  est.addedLatencyMs: \(estimatedLatencyMs(lowLatency: state.lowLatencyMode))")
        lines.append("selectedInputUID: \(state.selectedInputUID ?? "default")")
        lines.append("virtualMicInstalled: \(state.virtualMicInstalled)")
        switch state.status {
        case .stopped: lines.append("engine: stopped")
        case .running: lines.append("engine: running")
        case .error(let m): lines.append("engine: error: \(m)")
        }
        lines.append("inputDevices:")
        for d in state.devices.inputDevices {
            lines.append("  - \(d.name) [\(d.uid)]")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
