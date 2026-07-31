@preconcurrency import ScreenCaptureKit
import AudioToolbox
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import OSLog

/// Enumerates ScreenCaptureKit sources without persisting titles or process
/// details. Capture requires the user-granted Screen Recording TCC permission.
public struct SystemAudioSourceProvider: SystemAudioSourceProviding {
    public init() {}

    public func systemAudioSources() async throws -> [SystemAudioSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays.map {
            SystemAudioSource(
                id: "display:\($0.displayID)",
                displayName: "Display \($0.displayID) (system audio)",
                kind: .display
            )
        }
        let applications = content.applications.map {
            SystemAudioSource(
                id: "application:\($0.processID)",
                displayName: $0.applicationName,
                kind: .application
            )
        }
        return displays + applications
    }
}

/// Audio-only ScreenCaptureKit source. It intentionally never registers a
/// screen output; `capturesAudio` is the sole media path.
public final class SystemAudioInputSource: NSObject, AudioInputSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let stateStream: AsyncStream<AudioInputState>
    public let audioStream: AsyncThrowingStream<AudioFrame, Error>

    private let stateContinuation: AsyncStream<AudioInputState>.Continuation
    private let audioContinuation: AsyncThrowingStream<AudioFrame, Error>.Continuation
    private let lock = NSLock()
    private let outputQueue = DispatchQueue(label: "MacSpeechTranslator.systemAudioOutput", qos: .userInitiated)
    private let drainQueue = DispatchQueue(label: "MacSpeechTranslator.systemAudioDrain", qos: .userInitiated)
    private var stream: SCStream?
    private var ringBuffer: AudioRingBuffer?
    private var drainTimer: DispatchSourceTimer?
    private var audioBufferListScratch: AudioBufferListScratch?
    private var sampleRate = 48_000
    private var channelCount = 2
    private var isPrepared = false
    private var captureStartedAt: TimeInterval?
    private var streamDroppedFrames = 0

    public override init() {
        let statePair = AsyncStream<AudioInputState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stateStream = statePair.stream
        stateContinuation = statePair.continuation
        let audioPair = AsyncThrowingStream<AudioFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
        audioStream = audioPair.stream
        audioContinuation = audioPair.continuation
        super.init()
    }

    public func prepare(configuration: AudioInputConfiguration) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            DiagnosticsLogger.permissions.notice("Screen Recording permission denied or not granted.")
            stateContinuation.yield(.permissionDenied)
            throw MacSpeechTranslatorError.screenCapturePermissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let filter = makeFilter(content: content, sourceID: configuration.systemAudioSourceID) else {
            stateContinuation.yield(.unavailable("The selected system-audio source is no longer available."))
            throw MacSpeechTranslatorError.deviceNotFound
        }

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.capturesAudio = true
        streamConfiguration.excludesCurrentProcessAudio = true
        streamConfiguration.sampleRate = sampleRate
        streamConfiguration.channelCount = channelCount
        streamConfiguration.queueDepth = 3
        let captureStream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)

        lock.withLock {
            stream = captureStream
            ringBuffer = AudioRingBuffer(capacity: sampleRate * channelCount * 3)
            audioBufferListScratch = AudioBufferListScratch(maximumBufferCount: channelCount)
            isPrepared = true
        }
        stateContinuation.yield(.prepared)
    }

    public func start() async throws {
        let captureStream = lock.withLock { isPrepared ? stream : nil }
        guard let captureStream else { throw MacSpeechTranslatorError.deviceNotFound }
        do {
            try await captureStream.startCapture()
            lock.withLock {
                captureStartedAt = ProcessInfo.processInfo.systemUptime
                streamDroppedFrames = 0
            }
            startDraining()
            stateContinuation.yield(.recording)
            DiagnosticsLogger.audio.notice("System-audio capture started.")
        } catch {
            stateContinuation.yield(.failed("Unable to start system-audio capture."))
            DiagnosticsLogger.audio.error("System-audio capture failed to start.")
            throw error
        }
    }

    public func stop() async {
        let captureStream: SCStream? = lock.withLock {
            drainTimer?.cancel()
            drainTimer = nil
            ringBuffer?.reset()
            captureStartedAt = nil
            isPrepared = false
            return stream
        }
        if let captureStream {
            try? await captureStream.stopCapture()
        }
        stateContinuation.yield(.stopped)
        DiagnosticsLogger.audio.notice("System-audio capture stopped.")
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

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        copyAudioBuffer(sampleBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        DiagnosticsLogger.audio.error("System-audio stream stopped with an error.")
        stateContinuation.yield(.failed("System-audio source stopped: \(error.localizedDescription)"))
        Task { [weak self] in await self?.stop() }
    }

    private func makeFilter(content: SCShareableContent, sourceID: String?) -> SCContentFilter? {
        let ownProcessID = getpid()
        let excluded = content.applications.filter { $0.processID == ownProcessID }

        guard let sourceID else {
            guard let display = content.displays.first else { return nil }
            return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        }
        if let displayID = UInt32(sourceID.replacingOccurrences(of: "display:", with: "")),
           let display = content.displays.first(where: { $0.displayID == displayID }) {
            return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        }
        if let processID = pid_t(sourceID.replacingOccurrences(of: "application:", with: "")),
           let application = content.applications.first(where: { $0.processID == processID }),
           let display = content.displays.first {
            return SCContentFilter(display: display, including: [application], exceptingWindows: [])
        }
        return nil
    }

    private func copyAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              description.pointee.mFormatID == kAudioFormatLinearPCM,
              description.pointee.mBitsPerChannel == 32,
              (description.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0 else {
            return
        }

        let formatDescription = description.pointee
        let channels = max(Int(formatDescription.mChannelsPerFrame), 1)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        let captureResources: (AudioRingBuffer, AudioBufferListScratch)? = lock.withLock {
            guard let ringBuffer, let audioBufferListScratch else { return nil }
            return (ringBuffer, audioBufferListScratch)
        }
        guard let (ring, scratch) = captureResources else { return }
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: scratch.pointer,
            bufferListSize: scratch.byteCount,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(scratch.pointer)
        let nonInterleaved = (formatDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        if nonInterleaved {
            _ = ring.writePlanar(buffers, channelCount: channels, frameCount: frames)
        } else if let data = buffers.first?.mData {
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames * channels)
            _ = ring.write(samples)
        }
    }

    private func startDraining() {
        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        let samplesPerTick = sampleRate * channelCount / 50
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            self?.drain(maximumSamples: samplesPerTick)
        }
        lock.withLock { drainTimer = timer }
        timer.resume()
    }

    private func drain(maximumSamples: Int) {
        let setup: (AudioRingBuffer?, TimeInterval?) = lock.withLock { (ringBuffer, captureStartedAt) }
        guard let ring = setup.0 else { return }
        let samples = ring.read(maximumSamples: maximumSamples)
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
}

private final class AudioBufferListScratch: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    let byteCount: Int

    init(maximumBufferCount: Int) {
        let bufferCount = max(maximumBufferCount, 1)
        byteCount = MemoryLayout<AudioBufferList>.size + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.stride
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        rawPointer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        pointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
    }

    deinit {
        UnsafeMutableRawPointer(pointer).deallocate()
    }
}
