import SwiftUI
import AVFoundation

/// First-run onboarding (PRD 2.2 / APP-02): permission → virtual mic → test. Target < 3분.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    var body: some View {
        VStack(spacing: 18) {
            Text("Crisp 시작하기").font(.title2.bold())
            ProgressView(value: Double(step + 1), total: 3).frame(maxWidth: 260)

            Group {
                switch step {
                case 0: micStep
                case 1: virtualMicStep
                default: testStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if step > 0 { Button("이전") { step -= 1 } }
                Spacer()
                if step < 2 {
                    Button("다음") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
    }

    private var micStep: some View {
        VStack(spacing: 12) {
            Image(systemName: micGranted ? "checkmark.circle.fill" : "mic.fill")
                .font(.system(size: 48)).foregroundStyle(micGranted ? Color.green : Color.accentColor)
            Text("1. 마이크 권한").font(.headline)
            Text("Crisp가 마이크 입력을 처리하려면 권한이 필요합니다.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if micGranted {
                Text("권한이 허용되었습니다.").foregroundStyle(.green)
            } else {
                Button("마이크 권한 요청") {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async { micGranted = granted }
                    }
                }
            }
        }
    }

    private var virtualMicStep: some View {
        VStack(spacing: 12) {
            Image(systemName: state.virtualMicInstalled ? "checkmark.circle.fill" : "waveform.badge.plus")
                .font(.system(size: 48)).foregroundStyle(state.virtualMicInstalled ? Color.green : Color.accentColor)
            Text("2. 가상 마이크").font(.headline)
            if state.virtualMicInstalled {
                Text("“Noise Cancelled Microphone” 가상 마이크가 설치되었습니다.")
                    .multilineTextAlignment(.center).foregroundStyle(.green)
            } else {
                Text("가상 마이크 드라이버를 설치해야 합니다. 터미널에서 다음을 실행하세요:")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("sudo ./scripts/install-driver.sh")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button("상태 새로고침") { state.devices.refresh() }
            }
        }
    }

    private var testStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text("3. 테스트").font(.headline)
            Text("회의 앱의 마이크로 “Noise Cancelled Microphone”을 선택하고,\n메뉴바에서 노이즈 캔슬링을 켜세요.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Toggle("지금 노이즈 캔슬링 켜기", isOn: $state.isEnabled).toggleStyle(.switch)
        }
    }
}
