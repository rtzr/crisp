import Foundation
import AVFoundation
import CoreAudio
import OSLog
import CrispEngine

private let audioLog = Logger(subsystem: "ai.rtzr.crisp", category: "audio")

protocol AudioEngineControlling: AnyObject {
    func start(config: AudioProcessingConfig, inputUID: String?, lowLatency: Bool)
    func stop()
    func update(config: AudioProcessingConfig)
}

/// Live capture engine (PRD 6.2):
///   physical mic capture → AVAudioConverter(→48k mono) → two-stage pipeline
///   (DeepFilter denoise → Voice Enhancer DSP) → ring buffer → AUHAL output
///   → Crisp virtual device → loopback → meeting app
///
/// Any mic sample rate is supported: the converter normalizes to the model's 48 kHz mono.
final class LiveAudioEngine: AudioEngineControlling {
    private weak var state: AppState?
    private let engine = AVAudioEngine()
    private var pipeline: PipelineProcessor?
    private var output: VirtualMicOutput?
    private var converter: AVAudioConverter?
    private let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private var running = false
    private var lastMeterNs: UInt64 = 0   // throttle gate for UI meter updates

    init(state: AppState) {
        self.state = state
    }

    func start(config: AudioProcessingConfig, inputUID: String?, lowLatency: Bool) {
        requestMicAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.setStatus(.error("마이크 권한이 거부되었습니다."))
                return
            }
            self.startLocked(config: config, inputUID: inputUID, lowLatency: lowLatency)
        }
    }

    private func startLocked(config: AudioProcessingConfig, inputUID: String?, lowLatency: Bool) {
        stop()

        if let uid = inputUID, let deviceID = Self.deviceID(forUID: uid) {
            Self.setInputDevice(engine, deviceID: deviceID)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            setStatus(.error("입력 장치를 열 수 없습니다."))
            return
        }

        // Noise Cancellation stage: DeepFilter model, low-latency or full (PRD SET-01).
        // Load here (not RT-safe); fall back to passthrough if it fails.
        let model: DeepFilterSuppressor.Model = lowLatency ? .lowLatency : .full
        let suppressor: NoiseSuppressor
        if let modelPath = DeepFilterSuppressor.modelPath(model),
           let df = DeepFilterSuppressor(modelPath: modelPath) {
            suppressor = df
        } else {
            suppressor = PassthroughSuppressor()
        }
        // Two-stage pipeline (denoise → Voice Enhancer DSP). Mode/strength/tone come from config.
        let pipe = PipelineProcessor(suppressor: suppressor, sampleRate: 48_000, config: config)
        pipe.prepare(config: config)
        pipeline = pipe

        // Resampler: input (any rate, any channels) → 48 kHz mono for the model.
        converter = AVAudioConverter(from: format, to: canonical)

        // PRD SET-02: log input / model / output sample rates (no PII).
        audioLog.info("engine start — input SR=\(format.sampleRate, privacy: .public)Hz ch=\(format.channelCount, privacy: .public) → model/virtual-mic SR=48000Hz mono")

        // Route to the Crisp virtual mic when installed (output is always 48k now).
        if let crispID = Self.deviceID(forUID: AudioDeviceManager.crispVirtualUID) {
            let out = VirtualMicOutput()
            do { try out.start(deviceID: crispID); output = out }
            catch { setStatus(.error("가상 마이크 출력 연결 실패: \(error.localizedDescription)")) }
        } else {
            setStatus(.error("가상 마이크가 설치되지 않았습니다. pkg 설치 후 다시 시도하세요."))
        }

        input.installTap(onBus: 0, bufferSize: 480, format: format) { [weak self] buffer, _ in
            guard let self, let canonicalSamples = self.toCanonicalMono(buffer), !canonicalSamples.isEmpty else { return }
            let inLevel = Self.rms(canonicalSamples)
            // Two-stage pipeline: DeepFilter denoise (~0.97 ms/hop) → Voice Enhancer DSP.
            let processed = self.pipeline?.process(canonicalSamples) ?? canonicalSamples
            if !processed.isEmpty {
                processed.withUnsafeBufferPointer { self.output?.pushMono($0.baseAddress!, count: $0.count) }
            }
            let outLevel = processed.isEmpty ? inLevel : Self.rms(processed)
            // Throttle UI meter updates to ~15 Hz (the tap fires ~100 Hz). Flooding the main
            // thread with @Published updates was the UI-responsiveness bottleneck.
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- self.lastMeterNs >= 66_000_000 {
                self.lastMeterNs = now
                DispatchQueue.main.async { self.state?.meters.set(input: inLevel, output: outLevel) }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            running = true
            setStatus(.running)
        } catch {
            setStatus(.error("오디오 엔진 시작 실패: \(error.localizedDescription)"))
        }
    }

    func stop() {
        guard running || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        output?.stop()
        output = nil
        converter = nil
        pipeline = nil
        running = false
        DispatchQueue.main.async { self.state?.meters.set(input: 0, output: 0) }
        setStatus(.stopped)
    }

    /// Apply mode/strength/tone/bypass live — ramps inside the pipeline, no teardown (PRD 8.4).
    func update(config: AudioProcessingConfig) {
        pipeline?.update(config: config)
    }

    // MARK: - Helpers

    private func setStatus(_ status: EngineStatus) {
        DispatchQueue.main.async { self.state?.status = status }
    }

    private func requestMicAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }

    /// Convert any-rate/any-channel tap buffer → 48 kHz mono Float samples.
    private func toCanonicalMono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let ratio = canonical.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: cap) else { return nil }
        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        let n = Int(outBuf.frameLength)
        guard n > 0, let ptr = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: n))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))   // map to 0...1 (~ -60 dB floor)
        return min(1, max(0, (db + 60) / 60))
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var outSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let inSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            withUnsafeMutablePointer(to: &deviceID) { devPtr in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, inSize, uidPtr, &outSize, devPtr)
            }
        }
        return (status == noErr && deviceID != 0) ? deviceID : nil
    }

    private static func setInputDevice(_ engine: AVAudioEngine, deviceID: AudioDeviceID) {
        guard let unit = engine.inputNode.audioUnit else { return }
        var dev = deviceID
        AudioUnitSetProperty(unit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             0,
                             &dev,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }
}
