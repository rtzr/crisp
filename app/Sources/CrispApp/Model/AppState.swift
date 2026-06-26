import Foundation
import Combine
import ServiceManagement
import CrispEngine

/// Noise-suppression strength. PRD RT-04: at least 3 steps or a continuous slider.
enum NoiseStrength: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "약하게"
        case .medium: return "보통"
        case .high: return "강하게"
        }
    }

    /// Attenuation limit (dB) handed to the model. Lower magnitude = gentler.
    var attenuationLimitDb: Float {
        switch self {
        case .low: return 12
        case .medium: return 24
        case .high: return 100   // effectively full suppression
        }
    }
}

// Korean display labels for the engine's processing enums (PRD 2.2 / 3.2). Kept in the app
// layer so CrispEngine stays UI/locale-free.
extension ProcessingMode {
    var label: String {
        switch self {
        case .off:               return "끄기"
        case .noiseCancellation: return "노이즈 캔슬링"
        case .voiceEnhancer:     return "보이스 인핸서"
        case .cleanAndEnhance:   return "클린 + 인핸스"
        }
    }
    var shortLabel: String {
        switch self {
        case .off:               return "Off"
        case .noiseCancellation: return "노이즈"
        case .voiceEnhancer:     return "인핸스"
        case .cleanAndEnhance:   return "클린+인핸스"
        }
    }
}

extension EnhanceStrength {
    var label: String {
        switch self {
        case .low:    return "약하게"
        case .medium: return "보통"
        case .high:   return "강하게"
        }
    }
}

extension TonePreset {
    var label: String {
        switch self {
        case .natural: return "자연스럽게"
        case .warm:    return "따뜻하게"
        case .bright:  return "밝게"
        }
    }
}

/// Holds only the high-frequency level-meter values, observed solely by the meter views.
/// Keeping these out of AppState prevents 100 Hz audio updates from invalidating the
/// entire popover (pickers, toggles, etc.) — the main UI-responsiveness fix.
@MainActor
final class MeterState: ObservableObject {
    @Published var input: Float = 0    // 0...1
    @Published var output: Float = 0   // 0...1

    func set(input: Float, output: Float) {
        self.input = input
        self.output = output
    }
}

enum EngineStatus: Equatable {
    case stopped
    case running
    case error(String)

    var isError: Bool { if case .error = self { return true }; return false }
}

/// Single source of truth for UI + engine, with UserDefaults persistence (PRD APP-03).
@MainActor
final class AppState: ObservableObject {
    @Published var isEnabled: Bool { didSet { persist(); syncEnable() } }
    @Published var isBypassed: Bool { didSet { persist(); applyParams() } }            // A/B monitor (FR-RT-005)
    @Published var mode: ProcessingMode { didSet { persist(); applyParams() } }        // FR-RT-002
    @Published var strength: NoiseStrength { didSet { persist(); applyParams() } }     // noise (RT-04)
    @Published var enhanceStrength: EnhanceStrength { didSet { persist(); applyParams() } }  // FR-RT-003
    @Published var tonePreset: TonePreset { didSet { persist(); applyParams() } }      // tone (3.2)
    @Published var selectedInputUID: String? { didSet { persist(); restartEngine() } }
    @Published var lowLatencyMode: Bool { didSet { persist(); restartEngine() } }      // PRD SET-01 (reloads model)
    @Published var launchAtLogin: Bool { didSet { persist(); applyLaunchAtLogin() } }

    // Live telemetry. Level meters live in their own object (`meters`) so high-frequency
    // updates only re-render the meter views, not the whole popover/settings UI.
    @Published var status: EngineStatus = .stopped
    @Published var virtualMicInstalled: Bool = false

    let meters = MeterState()
    let devices = AudioDeviceManager()
    private(set) lazy var engine: AudioEngineControlling = LiveAudioEngine(state: self)
    private var cancellables = Set<AnyCancellable>()

    private enum Keys {
        static let isEnabled = "isEnabled"
        static let isBypassed = "isBypassed"
        static let mode = "mode"
        static let strength = "strength"
        static let enhanceStrength = "enhanceStrength"
        static let tonePreset = "tonePreset"
        static let selectedInputUID = "selectedInputUID"
        static let lowLatencyMode = "lowLatencyMode"
        static let launchAtLogin = "launchAtLogin"
    }

    init() {
        let d = UserDefaults.standard
        self.isEnabled = d.object(forKey: Keys.isEnabled) as? Bool ?? false
        self.isBypassed = d.object(forKey: Keys.isBypassed) as? Bool ?? false
        self.mode = ProcessingMode(rawValue: d.string(forKey: Keys.mode) ?? "") ?? .cleanAndEnhance
        self.strength = NoiseStrength(rawValue: d.string(forKey: Keys.strength) ?? "") ?? .medium
        self.enhanceStrength = EnhanceStrength(rawValue: d.string(forKey: Keys.enhanceStrength) ?? "") ?? .medium
        self.tonePreset = TonePreset(rawValue: d.string(forKey: Keys.tonePreset) ?? "") ?? .natural
        self.selectedInputUID = d.string(forKey: Keys.selectedInputUID)
        self.lowLatencyMode = d.bool(forKey: Keys.lowLatencyMode)
        self.launchAtLogin = d.bool(forKey: Keys.launchAtLogin)

        devices.refresh()
        virtualMicInstalled = devices.crispVirtualDevice != nil

        // Keep virtual-mic presence in sync as devices come and go.
        devices.$inputDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.virtualMicInstalled = self.devices.crispVirtualDevice != nil
            }
            .store(in: &cancellables)

        if isEnabled { restartEngine() }
    }

    func toggleEnabled() { isEnabled.toggle() }

    /// The pipeline configuration for the current UI state. A bypass forces passthrough
    /// (mode `.off`) for instant A/B without tearing the engine down (PRD FR-RT-005).
    private func currentConfig() -> AudioProcessingConfig {
        AudioProcessingConfig(mode: isBypassed ? .off : mode,
                              sampleRate: 48_000,
                              noiseAttenuationDb: strength.attenuationLimitDb,
                              enhanceStrength: enhanceStrength,
                              tonePreset: tonePreset,
                              modelId: lowLatencyMode ? "DeepFilterNet3_ll_onnx" : "DeepFilterNet3_onnx")
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(isEnabled, forKey: Keys.isEnabled)
        d.set(isBypassed, forKey: Keys.isBypassed)
        d.set(mode.rawValue, forKey: Keys.mode)
        d.set(strength.rawValue, forKey: Keys.strength)
        d.set(enhanceStrength.rawValue, forKey: Keys.enhanceStrength)
        d.set(tonePreset.rawValue, forKey: Keys.tonePreset)
        d.set(selectedInputUID, forKey: Keys.selectedInputUID)
        d.set(lowLatencyMode, forKey: Keys.lowLatencyMode)
        d.set(launchAtLogin, forKey: Keys.launchAtLogin)
    }

    /// Register/unregister the app as a login item (PRD APP-04). Requires running from a bundle.
    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Crisp: launch-at-login 변경 실패: \(error.localizedDescription)")
        }
    }

    /// Master on/off: start or stop the capture engine.
    private func syncEnable() {
        if isEnabled { restartEngine() } else { engine.stop() }
    }

    /// (Re)start the engine — needed when the input device or model (low-latency) changes.
    private func restartEngine() {
        guard isEnabled else { return }
        engine.start(config: currentConfig(), inputUID: selectedInputUID, lowLatency: lowLatencyMode)
    }

    /// Apply mode/strength/tone/bypass live — no teardown, so it is click-free (PRD 8.4).
    private func applyParams() {
        guard isEnabled else { return }
        engine.update(config: currentConfig())
    }
}
