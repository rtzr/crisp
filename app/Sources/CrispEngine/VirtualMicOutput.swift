import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Writes processed audio into the Crisp virtual device's output stream so meeting apps
/// reading "Noise Cancelled Microphone" receive it (loopback in the HAL driver).
///
/// Pattern: capture tap → SPSC ring buffer → AUHAL output unit (device = Crisp) render
/// callback. Output format matches the driver ASBD: 48 kHz, 2ch, Float32 interleaved.
public final class VirtualMicOutput {
    private var unit: AudioUnit?
    private let ring: FloatRing
    private let channels = 2
    private let sampleRate = 48_000.0

    public init(ringCapacityFrames: Int = 48_000) {
        ring = FloatRing(capacity: ringCapacityFrames * 2)   // stereo interleaved
    }

    /// Push mono Float samples; duplicated to L/R for the stereo device.
    public func pushMono(_ samples: UnsafePointer<Float>, count: Int) {
        ring.writeMonoAsStereo(samples, count: count)
    }

    /// Frames currently buffered (for drain detection in tools).
    public var bufferedFrames: Int { ring.available / channels }

    public func start(deviceID: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw err("HALOutput 컴포넌트 없음") }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "AudioComponentInstanceNew")
        guard let unit = u else { throw err("AudioUnit 생성 실패") }
        self.unit = unit

        // Enable output (bus 0), disable input (bus 1).
        var enable: UInt32 = 1, disable: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size)), "enable output")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, UInt32(MemoryLayout<UInt32>.size)), "disable input")

        // Target the Crisp virtual device.
        var dev = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")

        // Stream format = driver ASBD.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "stream format")

        // Render callback pulls from the ring.
        var cb = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "render callback")

        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
    }

    public func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        ring.reset()
    }

    fileprivate func render(_ ioData: UnsafeMutablePointer<AudioBufferList>?, frames: UInt32) -> OSStatus {
        guard let ioData else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        guard let buf = abl.first, let mData = buf.mData else { return noErr }
        let needed = Int(frames) * channels
        ring.read(into: mData.assumingMemoryBound(to: Float.self), count: needed)
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw err("\(what) 실패 (\(status))") }
    }
    private func err(_ m: String) -> NSError { NSError(domain: "Crisp.VirtualMicOutput", code: -1, userInfo: [NSLocalizedDescriptionKey: m]) }
}

/// Render callback (C function pointer). Pulls processed audio from the ring buffer.
private func renderCallback(inRefCon: UnsafeMutableRawPointer,
                            ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            inTimeStamp: UnsafePointer<AudioTimeStamp>,
                            inBusNumber: UInt32,
                            inNumberFrames: UInt32,
                            ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let me = Unmanaged<VirtualMicOutput>.fromOpaque(inRefCon).takeUnretainedValue()
    return me.render(ioData, frames: inNumberFrames)
}

/// Single-producer/single-consumer float ring buffer. Underruns emit silence.
final class FloatRing {
    private var buffer: [Float]
    private let capacity: Int
    private var writeIdx = 0
    private var readIdx = 0
    private let lock = NSLock()

    init(capacity: Int) { self.capacity = capacity; buffer = [Float](repeating: 0, count: capacity) }

    func reset() { lock.lock(); writeIdx = 0; readIdx = 0; lock.unlock() }

    var available: Int { lock.lock(); defer { lock.unlock() }; return writeIdx - readIdx }

    func writeMonoAsStereo(_ samples: UnsafePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<count {
            let s = samples[i]
            buffer[writeIdx % capacity] = s; writeIdx += 1
            buffer[writeIdx % capacity] = s; writeIdx += 1
        }
    }

    func read(into dst: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        let available = writeIdx - readIdx
        for i in 0..<count {
            if i < available { dst[i] = buffer[readIdx % capacity]; readIdx += 1 }
            else { dst[i] = 0 }   // underrun → silence
        }
    }
}
