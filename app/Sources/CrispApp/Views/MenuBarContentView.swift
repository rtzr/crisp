import SwiftUI
import CrispEngine

struct MenuBarContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    private var isActive: Bool { state.isEnabled && !state.isBypassed && state.mode != .off }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Crisp")
                    .font(.headline)
                Spacer()
                Text(isActive ? "\(state.mode.label) 켜짐" : "꺼짐")
                    .font(.caption)
                    .foregroundStyle(isActive ? .green : .secondary)
            }

            Toggle("실시간 처리", isOn: $state.isEnabled)
                .toggleStyle(.switch)

            Divider()

            // Processing mode (PRD FR-RT-002).
            VStack(alignment: .leading, spacing: 4) {
                Text("처리 모드").font(.caption).foregroundStyle(.secondary)
                Picker("처리 모드", selection: $state.mode) {
                    ForEach(ProcessingMode.allCases) { m in Text(m.shortLabel).tag(m) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

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

            // Noise strength — only when the Noise Cancellation stage is active (PRD RT-04).
            if state.mode == .noiseCancellation || state.mode == .cleanAndEnhance {
                VStack(alignment: .leading, spacing: 4) {
                    Text("노이즈 강도").font(.caption).foregroundStyle(.secondary)
                    Picker("노이즈 강도", selection: $state.strength) {
                        ForEach(NoiseStrength.allCases) { s in Text(s.label).tag(s) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            // Enhance strength + tone — only when the Voice Enhancer stage is active (PRD FR-RT-003 / 3.2).
            if state.mode.usesEnhancer {
                VStack(alignment: .leading, spacing: 4) {
                    Text("인핸스 강도").font(.caption).foregroundStyle(.secondary)
                    Picker("인핸스 강도", selection: $state.enhanceStrength) {
                        ForEach(EnhanceStrength.allCases) { s in Text(s.label).tag(s) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("톤").font(.caption).foregroundStyle(.secondary)
                    Picker("톤", selection: $state.tonePreset) {
                        ForEach(TonePreset.allCases) { t in Text(t.label).tag(t) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            // Level meters (PRD APP/RT status display). Isolated in their own observer so
            // high-frequency level updates don't re-render the rest of this popover.
            MetersView(meters: state.meters)

            Toggle("바이패스 (원본 전달 · A/B 비교)", isOn: $state.isBypassed)
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
