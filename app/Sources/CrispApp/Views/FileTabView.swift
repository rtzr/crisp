import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import CrispEngine

@MainActor
final class FileTabModel: ObservableObject {
    @Published var inputURL: URL?
    @Published var mode: ProcessingMode = .cleanAndEnhance
    @Published var quality: FileQuality = .hq
    @Published var enhanceStrength: EnhanceStrength = .medium
    @Published var tonePreset: TonePreset = .natural
    @Published var noiseStrength: NoiseStrength = .high
    @Published var loudness: LoudnessTarget = .podcast
    @Published var format: OutputFormat = .wav

    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var isProcessing = false
    @Published var results: [URL] = []
    @Published var report: FileEnhanceReport?
    @Published var errorText: String?

    private let enhancer = FileEnhancer()
    private var player: AVAudioPlayer?
    private var lastPreview: URL?

    func setInput(_ url: URL) {
        inputURL = url; results = []; report = nil; errorText = nil; progress = 0; statusText = ""
    }
    func cancel() { enhancer.cancel() }
    func play(_ url: URL) { player = try? AVAudioPlayer(contentsOf: url); player?.play() }

    private func options(previewSeconds: Double? = nil) -> FileEnhanceOptions {
        FileEnhanceOptions(mode: mode, quality: quality, enhanceStrength: enhanceStrength,
                           tonePreset: tonePreset, noiseAttenuationDb: noiseStrength.attenuationLimitDb,
                           loudness: loudness, format: format, previewSeconds: previewSeconds)
    }

    /// Full-file processing → user-chosen output (PRD FR-FILE-005: never overwrites the input).
    func start() {
        guard let input = inputURL, !isProcessing else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = input.deletingPathExtension().lastPathComponent + "_crisp." + format.ext
        panel.allowedContentTypes = [format == .wav ? .wav : .mpeg4Audio]
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let opts = options(), enhancer = self.enhancer
        begin("처리 중…")
        Task.detached {
            do {
                let r = try enhancer.enhance(input: input, output: output, options: opts) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run { self.done([output], report: r) }
            } catch { await MainActor.run { self.fail(error) } }
        }
    }

    /// 15–30 s before/after preview to a temp file (PRD FR-FILE-003), then play it.
    func startPreview() {
        guard let input = inputURL, !isProcessing else { return }
        if let old = lastPreview { try? FileManager.default.removeItem(at: old) }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("crisp_preview_\(UInt32(truncatingIfNeeded: input.hashValue)).\(format.ext)")
        lastPreview = tmp
        let opts = options(previewSeconds: 20), enhancer = self.enhancer
        begin("미리듣기 생성 중…")
        Task.detached {
            do {
                _ = try enhancer.enhance(input: input, output: tmp, options: opts) { p in
                    Task { @MainActor in self.progress = p }
                }
                await MainActor.run { self.isProcessing = false; self.statusText = "미리듣기 재생"; self.play(tmp) }
            } catch { await MainActor.run { self.fail(error) } }
        }
    }

    private func begin(_ text: String) { isProcessing = true; errorText = nil; statusText = text; progress = 0; results = []; report = nil }
    private func done(_ urls: [URL], report: FileEnhanceReport?) { results = urls; self.report = report; isProcessing = false; statusText = "완료" }
    private func fail(_ error: Error) { isProcessing = false; errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
}

struct FileTabView: View {
    @StateObject private var model = FileTabModel()
    @State private var isTargeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                dropZone
                if let input = model.inputURL {
                    LabeledContent("입력 파일", value: input.lastPathComponent)
                }

                settings

                if model.isProcessing {
                    ProgressView(value: model.progress) { Text(model.statusText) }
                    Button("취소") { model.cancel() }
                } else {
                    HStack {
                        Button("미리듣기 (20초)") { model.startPreview() }
                            .disabled(model.inputURL == nil)
                        Spacer()
                        Button("음성 개선 시작") { model.start() }
                            .disabled(model.inputURL == nil)
                            .keyboardShortcut(.defaultAction)
                    }
                }

                resultsView
                if let err = model.errorText {
                    Label(err, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                }
            }
            .padding(4)
        }
    }

    private var settings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("처리 모드", selection: $model.mode) {
                    ForEach(ProcessingMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("품질", selection: $model.quality) {
                    Text("빠르게 (Fast)").tag(FileQuality.fast)
                    Text("고품질 (HQ)").tag(FileQuality.hq)
                }
                .pickerStyle(.segmented)

                if model.mode == .noiseCancellation || model.mode == .cleanAndEnhance {
                    Picker("노이즈 강도", selection: $model.noiseStrength) {
                        ForEach(NoiseStrength.allCases) { Text($0.label).tag($0) }
                    }
                }
                if model.mode.usesEnhancer {
                    Picker("인핸스 강도", selection: $model.enhanceStrength) {
                        ForEach(EnhanceStrength.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("톤", selection: $model.tonePreset) {
                        ForEach(TonePreset.allCases) { Text($0.label).tag($0) }
                    }
                }
                if model.quality == .hq {
                    Picker("음량 정규화", selection: $model.loudness) {
                        Text("팟캐스트 (-16 LUFS)").tag(LoudnessTarget.podcast)
                        Text("회의 (-18 LUFS)").tag(LoudnessTarget.meeting)
                        Text("끄기").tag(LoudnessTarget.none)
                    }
                }
                Picker("출력 포맷", selection: $model.format) {
                    ForEach(OutputFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .disabled(model.isProcessing)
            .padding(6)
        }
    }

    private var resultsView: some View {
        Group {
            if !model.results.isEmpty {
                GroupBox("결과 — 전후 비교") {
                    VStack(alignment: .leading, spacing: 6) {
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
                        if let r = model.report {
                            Divider()
                            Text(String(format: "출력 음량 %.1f LUFS · 피크 %.1f → %.1f dBFS · 적용 게인 %+.1f dB",
                                        r.outputLUFS, r.inputPeakDb, r.outputPeakDb, r.loudnessGainDb))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
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
            .frame(height: 100)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 26)).foregroundStyle(.tint)
                    Text("오디오/비디오 파일을 끌어다 놓거나 클릭해서 선택").font(.callout).foregroundStyle(.secondary)
                    Text("wav · mp3 · m4a · mp4 · mov").font(.caption2).foregroundStyle(.tertiary)
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
