import AudioToolbox
import CoreAudio
import Foundation

public struct AudioDeviceManager: AudioDeviceProviding {
    public init() {}

    public func inputDevices() async throws -> [AudioInputDevice] {
        try Self.enumerateInputDevices()
    }

    public func defaultInputDevice() async throws -> AudioInputDevice? {
        let defaultID = try Self.defaultInputDeviceID()
        return try Self.enumerateInputDevices().first { $0.id == String(defaultID) }
    }

    public static func enumerateInputDevices() throws -> [AudioInputDevice] {
        let defaultID = try defaultInputDeviceID()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        ))

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        try deviceIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw MacSpeechTranslatorError.deviceNotFound
            }
            try check(AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                baseAddress
            ))
        }

        return try deviceIDs.compactMap { id in
            let channelCount = try inputChannelCount(for: id)
            guard channelCount > 0 else { return nil }
            return AudioInputDevice(
                id: String(id),
                name: try deviceName(for: id),
                sampleRate: try nominalSampleRate(for: id),
                channelCount: channelCount,
                isDefault: id == defaultID
            )
        }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.stride)
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceID
        ))
        return deviceID
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount))
        guard byteCount >= UInt32(MemoryLayout<AudioBufferList>.stride) else { return 0 }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, rawBuffer))
        let audioBuffers = UnsafeMutableAudioBufferListPointer(rawBuffer.assumingMemoryBound(to: AudioBufferList.self))
        return audioBuffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(for deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let namePointer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        namePointer.initialize(to: nil)
        defer {
            namePointer.deinitialize(count: 1)
            namePointer.deallocate()
        }
        var byteCount = UInt32(MemoryLayout<CFString>.stride)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, namePointer))
        guard let name = namePointer.pointee?.takeUnretainedValue() else { return "Unknown input" }
        return name as String
    }

    private static func nominalSampleRate(for deviceID: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var byteCount = UInt32(MemoryLayout<Float64>.stride)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &sampleRate))
        return sampleRate
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw MacSpeechTranslatorError.storageFailed("Core Audio returned OSStatus \(status).")
        }
    }
}
