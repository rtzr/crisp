import Foundation
import CoreAudio

public enum CoreAudioDevices {
    public static let crispVirtualUID = "CrispAudioDevice:0"   // matches the HAL driver

    /// Resolve a CoreAudio device ID from its UID (e.g. the Crisp virtual mic).
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
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
}
