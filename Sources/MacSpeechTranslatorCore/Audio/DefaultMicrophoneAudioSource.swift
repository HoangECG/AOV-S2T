@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Captures a selected Core Audio input through AVAudioEngine's input node.
/// Its tap only copies planar samples to `AudioRingBuffer`; a serial worker
/// emits frames after the callback returns.
public final class DefaultMicrophoneAudioSource: AudioInputSource, @unchecked Sendable {
    public let stateStream: AsyncStream<AudioInputState>
    public let audioStream: AsyncThrowingStream<AudioFrame, Error>

    private let stateContinuation: AsyncStream<AudioInputState>.Continuation
    private let audioContinuation: AsyncThrowingStream<AudioFrame, Error>.Continuation
    private let lock = NSLock()
    private let workerQueue = DispatchQueue(label: "MacSpeechTranslator.microphoneDrain", qos: .userInitiated)
    private let deviceMonitorQueue = DispatchQueue(label: "MacSpeechTranslator.microphoneDeviceMonitor", qos: .utility)
    private var engine: AVAudioEngine?
    private var ringBuffer: AudioRingBuffer?
    private var drainTimer: DispatchSourceTimer?
    private var configuration: AudioInputConfiguration?
    private var nativeSampleRate = 48_000
    private var nativeChannelCount = 1
    private var isPrepared = false
    private var captureStartedAt: TimeInterval?
    private var streamDroppedFrames = 0
    private var monitoredDeviceID: AudioDeviceID?
    private var deviceAliveListener: AudioObjectPropertyListenerBlock?

    public init() {
        let statePair = AsyncStream<AudioInputState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stateStream = statePair.stream
        stateContinuation = statePair.continuation
        let audioPair = AsyncThrowingStream<AudioFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
        audioStream = audioPair.stream
        audioContinuation = audioPair.continuation
    }

    public func prepare(configuration: AudioInputConfiguration) async throws {
        let permitted = await requestMicrophonePermissionIfNeeded()
        guard permitted else {
            DiagnosticsLogger.permissions.notice("Microphone permission denied.")
            stateContinuation.yield(.permissionDenied)
            throw MacSpeechTranslatorError.microphonePermissionDenied
        }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        if let id = configuration.deviceID, let rawID = UInt32(id) {
            guard let audioUnit = inputNode.audioUnit else {
                stateContinuation.yield(.unavailable("The selected audio device cannot be configured."))
                throw MacSpeechTranslatorError.deviceNotFound
            }
            var deviceID = AudioDeviceID(rawID)
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.stride)
            )
            guard status == noErr else {
                stateContinuation.yield(.unavailable("Selected audio device is unavailable."))
                throw MacSpeechTranslatorError.deviceNotFound
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MacSpeechTranslatorError.invalidAudioFormat
        }

        let channels = Int(format.channelCount)
        let sampleRate = Int(format.sampleRate.rounded())
        let capacity = max(sampleRate * channels * 3, 4_096)
        let buffer = AudioRingBuffer(capacity: capacity)

        lock.withLock {
            self.configuration = configuration
            self.nativeSampleRate = sampleRate
            self.nativeChannelCount = channels
            self.ringBuffer = buffer
            self.engine = audioEngine
            self.isPrepared = true
        }
        let deviceID: AudioDeviceID
        if let configuredID = configuration.deviceID, let rawID = UInt32(configuredID) {
            deviceID = AudioDeviceID(rawID)
        } else {
            deviceID = try AudioDeviceManager.defaultInputDeviceID()
        }
        installDeviceAliveListener(for: deviceID)
        stateContinuation.yield(.prepared)
    }

    public func start() async throws {
        let setup: (AVAudioEngine, AudioRingBuffer, Int, Int, AudioInputConfiguration)? = lock.withLock {
            guard let engine, let ringBuffer, let configuration, isPrepared else { return nil }
            return (engine, ringBuffer, nativeSampleRate, nativeChannelCount, configuration)
        }
        guard let (audioEngine, _, sampleRate, channels, configuration) = setup else {
            throw MacSpeechTranslatorError.deviceNotFound
        }

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            self?.copyFromAudioCallback(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            stateContinuation.yield(.failed("Unable to start the selected audio device."))
            DiagnosticsLogger.audio.error("Microphone capture failed to start.")
            throw MacSpeechTranslatorError.deviceDisconnected
        }

        lock.withLock {
            captureStartedAt = ProcessInfo.processInfo.systemUptime
            streamDroppedFrames = 0
        }
        startDraining(sampleRate: sampleRate, channelCount: channels, frameMilliseconds: configuration.processingFrameMilliseconds)
        stateContinuation.yield(.recording)
        DiagnosticsLogger.audio.notice("Microphone capture started.")
    }

    public func stop() async {
        let audioEngine: AVAudioEngine? = lock.withLock {
            let current = engine
            drainTimer?.cancel()
            drainTimer = nil
            ringBuffer?.reset()
            captureStartedAt = nil
            isPrepared = false
            return current
        }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        removeDeviceAliveListener()
        stateContinuation.yield(.stopped)
        DiagnosticsLogger.audio.notice("Microphone capture stopped.")
    }

    public func captureMetrics() -> AudioCaptureMetrics {
        let snapshot: (AudioRingBuffer?, Int) = lock.withLock { (ringBuffer, streamDroppedFrames) }
        guard let buffer = snapshot.0 else { return AudioCaptureMetrics(droppedFrames: snapshot.1) }
        let overruns = buffer.overrunCount
        return AudioCaptureMetrics(
            ringBufferOverruns: overruns,
            ringBufferUnderruns: buffer.underrunCount,
            droppedFrames: snapshot.1,
            droppedSamples: overruns
        )
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    private func installDeviceAliveListener(for deviceID: AudioDeviceID) {
        removeDeviceAliveListener()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceAliveChange(deviceID: deviceID)
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, deviceMonitorQueue, listener)
        guard status == noErr else {
            DiagnosticsLogger.audio.error("Could not monitor selected microphone device state.")
            return
        }
        lock.withLock {
            monitoredDeviceID = deviceID
            deviceAliveListener = listener
        }
    }

    private func removeDeviceAliveListener() {
        let listenerInfo: (AudioDeviceID, AudioObjectPropertyListenerBlock)? = lock.withLock {
            guard let monitoredDeviceID, let deviceAliveListener else { return nil }
            self.monitoredDeviceID = nil
            self.deviceAliveListener = nil
            return (monitoredDeviceID, deviceAliveListener)
        }
        guard let (deviceID, listener) = listenerInfo else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, deviceMonitorQueue, listener)
    }

    private func handleDeviceAliveChange(deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 1
        var byteCount = UInt32(MemoryLayout<UInt32>.stride)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &isAlive)
        guard status == noErr, isAlive == 0 else { return }
        DiagnosticsLogger.audio.error("Selected microphone device became unavailable.")
        stateContinuation.yield(.unavailable("Selected audio device was disconnected."))
        Task { [weak self] in await self?.stop() }
    }

    private func copyFromAudioCallback(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let setup: (AudioRingBuffer, Int)? = lock.withLock {
            guard let ringBuffer else { return nil }
            return (ringBuffer, nativeChannelCount)
        }
        guard let (ringBuffer, channelCount) = setup else { return }
        _ = ringBuffer.writeNonInterleaved(
            channelData,
            channelCount: min(channelCount, Int(buffer.format.channelCount)),
            frameCount: Int(buffer.frameLength)
        )
    }

    private func startDraining(sampleRate: Int, channelCount: Int, frameMilliseconds: Int) {
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        let interval = max(frameMilliseconds, 10)
        let samplesPerTick = max(sampleRate * channelCount * interval / 1_000, channelCount)
        timer.schedule(deadline: .now(), repeating: .milliseconds(interval), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            self?.drain(maximumSamples: samplesPerTick, sampleRate: sampleRate, channelCount: channelCount)
        }
        lock.withLock { drainTimer = timer }
        timer.resume()
    }

    private func drain(maximumSamples: Int, sampleRate: Int, channelCount: Int) {
        let setup: (AudioRingBuffer?, TimeInterval?) = lock.withLock { (ringBuffer, captureStartedAt) }
        guard let buffer = setup.0 else { return }
        let samples = buffer.read(maximumSamples: maximumSamples)
        guard !samples.isEmpty else { return }
        let captureEnd = ProcessInfo.processInfo.systemUptime
        let timestamp = max(0, captureEnd - (setup.1 ?? captureEnd) - Double(samples.count / channelCount) / Double(sampleRate))
        let result = audioContinuation.yield(AudioFrame(
            samples: samples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            timestamp: timestamp,
            captureEndUptime: captureEnd
        ))
        if case .dropped = result {
            lock.withLock { streamDroppedFrames += 1 }
        }
    }

    deinit {
        removeDeviceAliveListener()
    }
}
