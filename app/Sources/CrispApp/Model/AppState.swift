import Foundation
import Combine
import ServiceManagement

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
    @Published var isEnabled: Bool { didSet { persist(); syncEngine() } }
    @Published var isBypassed: Bool { didSet { persist(); syncEngine() } }
    @Published var strength: NoiseStrength { didSet { persist(); syncEngine() } }
    @Published var selectedInputUID: String? { didSet { persist(); syncEngine() } }
    @Published var lowLatencyMode: Bool { didSet { persist(); syncEngine() } }   // PRD SET-01
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
        static let strength = "strength"
        static let selectedInputUID = "selectedInputUID"
        static let lowLatencyMode = "lowLatencyMode"
        static let launchAtLogin = "launchAtLogin"
    }

    init() {
        let d = UserDefaults.standard
        self.isEnabled = d.object(forKey: Keys.isEnabled) as? Bool ?? false
        self.isBypassed = d.object(forKey: Keys.isBypassed) as? Bool ?? false
        self.strength = NoiseStrength(rawValue: d.string(forKey: Keys.strength) ?? "") ?? .medium
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

        if isEnabled { syncEngine() }
    }

    func toggleEnabled() { isEnabled.toggle() }

    private func persist() {
        let d = UserDefaults.standard
        d.set(isEnabled, forKey: Keys.isEnabled)
        d.set(isBypassed, forKey: Keys.isBypassed)
        d.set(strength.rawValue, forKey: Keys.strength)
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

    private func syncEngine() {
        if isEnabled {
            engine.start(inputUID: selectedInputUID, strength: strength, bypassed: isBypassed, lowLatency: lowLatencyMode)
        } else {
            engine.stop()
        }
    }
}
