import SwiftUI

@main
struct CrispApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // Menu bar popover — the most-used controls (PRD 7.1).
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.isEnabled && !state.isBypassed ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        // Settings window (Audio / File / Diagnostics / About).
        Window("Crisp 설정", id: WindowID.settings) {
            SettingsView()
                .environmentObject(state)
                .frame(minWidth: 560, minHeight: 420)
        }
        .windowResizability(.contentMinSize)

        // First-run onboarding (PRD 2.2 / APP-02).
        Window("Crisp 시작하기", id: WindowID.onboarding) {
            OnboardingView()
                .environmentObject(state)
                .frame(width: 520, height: 460)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let settings = "settings"
    static let onboarding = "onboarding"
}
