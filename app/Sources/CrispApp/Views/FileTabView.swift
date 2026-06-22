import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import CrispEngine

@MainActor
final class FileTabModel: ObservableObject {
    @Published var inputURL: URL?
    @Published var format: OutputFormat = .wav
    @Published var attenDb: Double = 100            // single-mode strength (atten-lim dB)
    @Published var batchMode = false
    @Published var batchLevels: Set<Int> = [12, 24, 48, 100]
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var isProcessing = false
    @Published var results: [URL] = []
    @Published var errorText: String?

    static let presetLevels = [6, 12, 24, 48, 100]   // dB; 100 = full suppression

    private let enhancer = FileEnhancer()
    private var player: AVAudioPlayer?

    func setInput(_ url: URL) {
        inputURL = url; results = []; errorText = nil; progress = 0; statusText = ""
    }
    func toggleLevel(_ l: Int) { if batchLevels.contains(l) { batchLevels.remove(l) } else { batchLevels.insert(l) } }
    func cancel() { enhancer.cancel() }
    func play(_ url: URL) { player = try? AVAudioPlayer(contentsOf: url); player?.play() }

    func startSingle() {
        guard let input = inputURL, !isProcessing else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = input.deletingPathExtension().lastPathComponent + "_crisp." + format.ext
        panel.allowedContentTypes = [format == .wav ? .wav : .mpeg4Audio]
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let fmt = format, atten = Float(attenDb), enhancer = self.enhancer
        begin()
        Task.detached {
            do {
                try enhancer.enhance(input: input, output: output, format: fmt, attenuationDb: atten) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run { self.done([output]) }
            } catch { await MainActor.run { self.fail(error) } }
        }
    }

    func startBatch() {
        guard let input = inputURL, !isProcessing, !batchLevels.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "이 폴더에 저장"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let fmt = format, base = input.deletingPathExtension().lastPathComponent + "_crisp"
        let levels = batchLevels.sorted().map(Float.init), enhancer = self.enhancer
        begin()
        Task.detached {
            do {
                let out = try enhancer.enhanceBatch(input: input, outputDirectory: dir, baseName: base,
                                                    format: fmt, attenuationLevels: levels) { p, lvl in
                    Task { @MainActor in self.progress = p; self.statusText = "강도 \(Int(lvl))dB 처리 중…" }
                }
                await MainActor.run { self.done(out) }
            } catch { await MainActor.run { self.fail(error) } }
        }
    }

    private func begin() { isProcessing = true; errorText = nil; statusText = "처리 중…"; progress = 0; results = [] }
    private func done(_ urls: [URL]) { results = urls; isProcessing = false; statusText = "완료 (\(urls.count)개)" }
    private func fail(_ error: Error) { isProcessing = false; errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
}

struct FileTabView: View {
    @StateObject private var model = FileTabModel()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 14) {
            dropZone
            if let input = model.inputURL {
                LabeledContent("입력 파일", value: input.lastPathComponent)
            }

            Picker("출력 포맷", selection: $model.format) {
                ForEach(OutputFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented).disabled(model.isProcessing)

            Toggle("여러 강도 일괄 출력 (배치)", isOn: $model.batchMode).disabled(model.isProcessing)

            if model.batchMode {
                batchLevelPicker
            } else {
                strengthSlider
            }

            if model.isProcessing {
                ProgressView(value: model.progress) { Text(model.statusText) }
                Button("취소") { model.cancel() }
            } else {
                Button(model.batchMode ? "일괄 처리 (\(model.batchLevels.count)개 강도)" : "음성 개선 시작") {
                    if model.batchMode { model.startBatch() } else { model.startSingle() }
                }
                .disabled(model.inputURL == nil || (model.batchMode && model.batchLevels.isEmpty))
                .keyboardShortcut(.defaultAction)
            }

            resultsView
            if let err = model.errorText {
                Label(err, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
            }
            Spacer()
        }
        .padding(4)
    }

    private var strengthSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("강도 (감쇠 상한)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.attenDb)) dB").font(.caption.monospacedDigit())
            }
            Slider(value: $model.attenDb, in: 0...100, step: 1).disabled(model.isProcessing)
            Text("0 = 원본 유지 · 100 = 최대 노이즈 제거").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var batchLevelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("생성할 강도 (감쇠 상한 dB) — 선택한 만큼 파일 생성").font(.caption).foregroundStyle(.secondary)
            HStack {
                ForEach(FileTabModel.presetLevels, id: \.self) { lvl in
                    Toggle("\(lvl)", isOn: Binding(
                        get: { model.batchLevels.contains(lvl) },
                        set: { _ in model.toggleLevel(lvl) }))
                    .toggleStyle(.button)
                    .disabled(model.isProcessing)
                }
            }
        }
    }

    private var resultsView: some View {
        Group {
            if !model.results.isEmpty {
                GroupBox("결과 (\(model.results.count)개) — 전후/레벨 비교") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let input = model.inputURL {
                            HStack { Button("원본 재생") { model.play(input) }; Spacer() }
                        }
                        ForEach(model.results, id: \.self) { url in
                            HStack {
                                Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("재생") { model.play(url) }
                                Button("표시") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            .frame(height: 110)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 26)).foregroundStyle(.tint)
                    Text("오디오/비디오 파일을 끌어다 놓거나 클릭해서 선택").font(.callout).foregroundStyle(.secondary)
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
