import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            AudioSettingsView().tabItem { Label("오디오", systemImage: "mic") }
            FileTabView().tabItem { Label("파일", systemImage: "doc.badge.gearshape") }
            DiagnosticsView().tabItem { Label("진단", systemImage: "stethoscope") }
            AboutView().tabItem { Label("정보", systemImage: "info.circle") }
        }
        .padding(20)
    }
}

// MARK: - Audio (PRD 7.1 설정 창 - Audio)

struct AudioSettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("실시간 처리") {
                Toggle("노이즈 캔슬링 켜기", isOn: $state.isEnabled)
                Toggle("바이패스 (원본 신호 전달)", isOn: $state.isBypassed)
                Picker("강도", selection: $state.strength) {
                    ForEach(NoiseStrength.allCases) { Text($0.label).tag($0) }
                }
                Picker("처리 모드", selection: $state.lowLatencyMode) {
                    Text("기본 (고품질)").tag(false)
                    Text("저지연").tag(true)
                }
            }
            Section("입력 마이크") {
                Picker("입력 장치", selection: $state.selectedInputUID) {
                    Text("시스템 기본값").tag(String?.none)
                    ForEach(state.devices.inputDevices.filter { $0.uid != AudioDeviceManager.crispVirtualUID }) { dev in
                        Text(dev.name).tag(String?.some(dev.uid))
                    }
                }
                Button("장치 목록 새로고침") { state.devices.refresh() }
            }
            Section("가상 마이크") {
                HStack {
                    Image(systemName: state.virtualMicInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.virtualMicInstalled ? .green : .orange)
                    Text(state.virtualMicInstalled
                         ? "“Noise Cancelled Microphone” 사용 가능"
                         : "가상 마이크가 설치되지 않았습니다")
                }
                Text("회의 앱(Zoom/Meet/Slack 등)의 마이크 목록에서 “Noise Cancelled Microphone”을 선택하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("시작") {
                Toggle("로그인 시 자동 시작", isOn: $state.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Diagnostics (PRD 7.1 설정 창 - Diagnostics, SET-02/03/04)

struct DiagnosticsView: View {
    @EnvironmentObject var state: AppState
    @State private var lastExport: String?

    var body: some View {
        Form {
            Section("버전") {
                LabeledContent("앱 버전", value: Diagnostics.appVersion)
                LabeledContent("모델", value: Diagnostics.modelVersion)
                LabeledContent("빌드", value: Diagnostics.buildNumber)
            }
            Section("상태") {
                LabeledContent("엔진", value: statusText)
                LabeledContent("가상 마이크", value: state.virtualMicInstalled ? "설치됨" : "없음")
            }
            Section("진단 로그") {
                Text("진단 로그에는 음성 원본이 포함되지 않으며, 상태/오류 정보만 기록됩니다. (PRD SET-03)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("진단 로그 내보내기…") { exportLog() }
                if let path = lastExport {
                    Text("저장됨: \(path)").font(.caption).foregroundStyle(.green)
                }
            }
            Section("가상 마이크 드라이버") {
                Text("문제가 있으면 드라이버를 재설치하세요:")
                    .font(.caption).foregroundStyle(.secondary)
                Text("sudo ./scripts/install-driver.sh")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch state.status {
        case .stopped: return "정지됨"
        case .running: return "동작 중"
        case .error(let m): return "오류: \(m)"
        }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "crisp-diagnostics.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? Diagnostics.export(state: state).write(to: url, atomically: true, encoding: .utf8)
            lastExport = url.path
        }
    }
}

// MARK: - About (PRD SET-04)

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Crisp").font(.title.bold())
            Text("실시간 노이즈 캔슬링 · macOS").font(.subheadline).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            LabeledContent("앱 버전", value: Diagnostics.appVersion)
            LabeledContent("모델", value: Diagnostics.modelVersion)
            LabeledContent("빌드", value: Diagnostics.buildNumber)
            Spacer()
            Text("오픈소스 라이선스 고지는 LICENSES.md를 참고하세요.\nDeepFilterNet, tract 등.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
