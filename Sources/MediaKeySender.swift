import AudioToolbox
import AppKit

final class MediaKeySender {
    private let volumeStep: Float32 = 0.0625

    private enum KeyCode {
        static let soundUp = 0
        static let soundDown = 1
    }

    func sendVolumeUp() -> Float? {
        if let volume = adjustSystemVolume(by: volumeStep) {
            return volume
        }

        sendMediaKey(KeyCode.soundUp)
        return currentSystemVolume()
    }

    func sendVolumeDown() -> Float? {
        if let volume = adjustSystemVolume(by: -volumeStep) {
            return volume
        }

        sendMediaKey(KeyCode.soundDown)
        return currentSystemVolume()
    }

    func currentVolume() -> Float? {
        currentSystemVolume()
    }

    private func adjustSystemVolume(by delta: Float32) -> Float? {
        guard let outputDeviceID = defaultOutputDeviceID() else {
            return nil
        }

        let channels = volumeChannels(for: outputDeviceID)
        guard !channels.isEmpty else {
            return nil
        }

        // Read current volume from the first channel
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channels[0]
        )
        var volume = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let getStatus = AudioObjectGetPropertyData(
            outputDeviceID, &address, 0, nil, &dataSize, &volume
        )
        guard getStatus == noErr else {
            return nil
        }

        var nextVolume = min(max(volume + delta, 0), 1)

        // Set volume on all channels
        var allOK = true
        for channel in channels {
            address.mElement = channel
            let setStatus = AudioObjectSetPropertyData(
                outputDeviceID, &address, 0, nil, dataSize, &nextVolume
            )
            if setStatus != noErr { allOK = false }
        }

        guard allOK else {
            return nil
        }

        if nextVolume > 0 {
            clearMuteIfNeeded(for: outputDeviceID)
        }

        return nextVolume
    }

    private func volumeChannels(for deviceID: AudioObjectID) -> [UInt32] {
        // Try master channel (element 0) first
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &address) {
            return [kAudioObjectPropertyElementMain]
        }

        // Fall back to per-channel (elements 1, 2 for stereo)
        var result: [UInt32] = []
        for ch: UInt32 in 1...2 {
            address.mElement = ch
            if AudioObjectHasProperty(deviceID, &address) {
                result.append(ch)
            }
        }
        return result
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else {
            return nil
        }

        return deviceID
    }

    private func clearMuteIfNeeded(for outputDeviceID: AudioObjectID) {
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(outputDeviceID, &muteAddress) else {
            return
        }

        var unmuted: UInt32 = 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(
            outputDeviceID,
            &muteAddress,
            0,
            nil,
            dataSize,
            &unmuted
        )
    }

    private func currentSystemVolume() -> Float? {
        guard let outputDeviceID = defaultOutputDeviceID() else {
            return nil
        }

        let channels = volumeChannels(for: outputDeviceID)
        guard let channel = channels.first else {
            return nil
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        var volume = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            outputDeviceID,
            &address,
            0,
            nil,
            &dataSize,
            &volume
        )

        guard status == noErr else {
            return nil
        }

        return volume
    }

    private func sendMediaKey(_ keyCode: Int) {
        postSystemDefinedEvent(keyCode: keyCode, isDown: true)
        postSystemDefinedEvent(keyCode: keyCode, isDown: false)
    }

    private func postSystemDefinedEvent(keyCode: Int, isDown: Bool) {
        let keyState = isDown ? 0xA : 0xB
        let data1 = (keyCode << 16) | (keyState << 8)

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else {
            return
        }

        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
