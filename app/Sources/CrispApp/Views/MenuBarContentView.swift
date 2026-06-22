import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Crisp")
                    .font(.headline)
                Spacer()
                Text(state.isEnabled && !state.isBypassed ? "노이즈 캔슬링 켜짐" : "꺼짐")
                    .font(.caption)
                    .foregroundStyle(state.isEnabled && !state.isBypassed ? .green : .secondary)
            }

            Toggle("노이즈 캔슬링", isOn: $state.isEnabled)
                .toggleStyle(.switch)

            Divider()

            // Input mic picker (PRD RT-01).
            VStack(alignment: .leading, spacing: 4) {
                Text("입력 마이크").font(.caption).foregroundStyle(.secondary)
                Picker("입력 마이크", selection: $state.selectedInputUID) {
                    Text("시스템 기본값").tag(String?.none)
                    ForEach(state.devices.inputDevices.filter { $0.uid != AudioDeviceManager.crispVirtualUID }) { dev in
                        Text(dev.name).tag(String?.some(dev.uid))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            // Strength (PRD RT-04).
            VStack(alignment: .leading, spacing: 4) {
                Text("강도").font(.caption).foregroundStyle(.secondary)
                Picker("강도", selection: $state.strength) {
                    ForEach(NoiseStrength.allCases) { s in Text(s.label).tag(s) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // Level meters (PRD APP/RT status display). Isolated in their own observer so
            // high-frequency level updates don't re-render the rest of this popover.
            MetersView(meters: state.meters)

            Toggle("바이패스 (원본 전달)", isOn: $state.isBypassed)
                .toggleStyle(.checkbox)
                .font(.caption)

            if !state.virtualMicInstalled {
                Label("가상 마이크가 설치되지 않았습니다", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if case let .error(message) = state.status {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button("설정…") { openWindow(id: WindowID.settings); activate() }
                Spacer()
                Button("종료") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func activate() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// Observes only MeterState, so the ~15 Hz level updates re-render just these two bars.
struct MetersView: View {
    @ObservedObject var meters: MeterState
    var body: some View {
        VStack(spacing: 6) {
            LevelMeter(label: "입력", level: meters.input)
            LevelMeter(label: "출력", level: meters.output)
        }
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float   // 0...1

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(level > 0.85 ? Color.red : .green)
                        .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
                }
            }
            .frame(height: 6)
        }
    }
}
