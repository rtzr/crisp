import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import CrispEngine

@MainActor
final class FileTabModel: ObservableObject {
    @Published var inputURL: URL?
    @Published var format: OutputFormat = .wav
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var isProcessing = false
    @Published var resultURL: URL?
    @Published var errorText: String?

    private let enhancer = FileEnhancer()
    private var player: AVAudioPlayer?

    func setInput(_ url: URL) {
        inputURL = url
        resultURL = nil
        errorText = nil
        progress = 0
        statusText = ""
    }

    func start() {
        guard let input = inputURL, !isProcessing else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = input.deletingPathExtension().lastPathComponent + "_crisp." + format.ext
        panel.allowedContentTypes = [format == .wav ? .wav : .mpeg4Audio]
        guard panel.runModal() == .OK, let output = panel.url else { return }

        isProcessing = true
        errorText = nil
        statusText = "처리 중…"
        let fmt = format
        Task.detached { [enhancer] in
            do {
                try enhancer.enhance(input: input, output: output, format: fmt, attenuationDb: 100) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run { self.resultURL = output; self.isProcessing = false; self.statusText = "완료" }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    func cancel() { enhancer.cancel() }

    func play(_ url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}

struct FileTabView: View {
    @StateObject private var model = FileTabModel()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            dropZone

            if let input = model.inputURL {
                LabeledContent("입력 파일", value: input.lastPathComponent)
            }

            Picker("출력 포맷", selection: $model.format) {
                ForEach(OutputFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.isProcessing)

            if model.isProcessing {
                ProgressView(value: model.progress) { Text(model.statusText) }
                Button("취소") { model.cancel() }
            } else {
                Button("음성 개선 시작") { model.start() }
                    .disabled(model.inputURL == nil)
                    .keyboardShortcut(.defaultAction)
            }

            if let result = model.resultURL {
                GroupBox("결과 (전후 비교 — PRD FILE-04)") {
                    HStack {
                        Button("원본 재생") { if let i = model.inputURL { model.play(i) } }
                        Button("개선본 재생") { model.play(result) }
                        Spacer()
                        Button("Finder에 표시") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                    }
                }
            }
            if let err = model.errorText {
                Label(err, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
            }
            Spacer()
        }
        .padding(4)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            .frame(height: 120)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 28)).foregroundStyle(.tint)
                    Text("오디오/비디오 파일을 끌어다 놓거나 클릭해서 선택")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("wav · mp3 · m4a · mp4").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { pickFile() }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.setInput(url) } }
                }
                return true
            }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .wav, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.setInput(url) }
    }
}
