import Foundation
@preconcurrency import AVFoundation

public enum AudioChannelMixer {
    public static func mixToMono(_ samples: [Float], channelCount: Int, selection: AudioChannelSelection) -> [Float] {
        guard channelCount > 1 else { return samples }
        let frameCount = samples.count / channelCount
        var output = [Float]()
        output.reserveCapacity(frameCount)

        switch selection {
        case .channel(let selectedChannel):
            let index = min(max(selectedChannel, 0), channelCount - 1)
            for frame in 0..<frameCount {
                output.append(samples[frame * channelCount + index])
            }
        case .downmix:
            let divisor = Float(channelCount)
            for frame in 0..<frameCount {
                let start = frame * channelCount
                var total: Float = 0
                for channel in 0..<channelCount {
                    total += samples[start + channel]
                }
                output.append(total / divisor)
            }
        }
        return output
    }
}

/// Deterministic linear interpolation resampler used as a dependency-free
/// fallback. It runs on the processing task, never on the capture callback.
public struct LinearAudioResampler: AudioResampling {
    public init() {}

    public func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) throws -> [Float] {
        guard sourceRate > 0, targetRate > 0 else {
            throw MacSpeechTranslatorError.invalidAudioFormat
        }
        guard sourceRate != targetRate, samples.count > 1 else { return samples }

        let targetCount = max(1, Int((Double(samples.count) * Double(targetRate) / Double(sourceRate)).rounded()))
        let scale = Double(sourceRate) / Double(targetRate)
        var output = [Float]()
        output.reserveCapacity(targetCount)

        for outputIndex in 0..<targetCount {
            let sourcePosition = min(Double(outputIndex) * scale, Double(samples.count - 1))
            let lower = Int(sourcePosition)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            output.append(samples[lower] + (samples[upper] - samples[lower]) * fraction)
        }
        return output
    }
}

/// Core Audio's converter is the preferred production resampler. The linear
/// implementation remains available as a deterministic fallback for malformed
/// device formats and unit-level tests.
public struct AVAudioConverterResampler: AudioResampling {
    public init() {}

    public func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) throws -> [Float] {
        guard sourceRate > 0, targetRate > 0 else { throw MacSpeechTranslatorError.invalidAudioFormat }
        guard sourceRate != targetRate, !samples.isEmpty else { return samples }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sourceRate),
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetRate),
            channels: 1,
            interleaved: false
        ), let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw MacSpeechTranslatorError.invalidAudioFormat
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let inputPointer = inputBuffer.floatChannelData?.pointee else {
            throw MacSpeechTranslatorError.invalidAudioFormat
        }
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            inputPointer.update(from: baseAddress, count: source.count)
        }

        let outputCapacity = AVAudioFrameCount(ceil(Double(samples.count) * Double(targetRate) / Double(sourceRate))) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MacSpeechTranslatorError.invalidAudioFormat
        }
        // Live input has no future samples for converter priming. This avoids
        // truncating a short realtime frame while accepting the documented
        // low-latency trade-off at its boundary.
        converter.primeMethod = .none
        let inputSupplier = ConverterInputSupplier(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            inputSupplier.next(status: outputStatus)
        }
        if let conversionError { throw conversionError }
        guard status == .haveData || status == .inputRanDry || status == .endOfStream,
              let outputPointer = outputBuffer.floatChannelData?.pointee else {
            throw MacSpeechTranslatorError.invalidAudioFormat
        }
        let result = Array(UnsafeBufferPointer(start: outputPointer, count: Int(outputBuffer.frameLength)))
        let expectedCount = Int((Double(samples.count) * Double(targetRate) / Double(sourceRate)).rounded())
        guard abs(result.count - expectedCount) <= max(8, expectedCount / 50) else {
            throw MacSpeechTranslatorError.invalidAudioFormat
        }
        return result
    }
}

private final class ConverterInputSupplier: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        lock.withLock {
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}

public struct PreferredAudioResampler: AudioResampling {
    private let converter = AVAudioConverterResampler()
    private let fallback = LinearAudioResampler()

    public init() {}

    public func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) throws -> [Float] {
        do {
            return try converter.resample(samples, from: sourceRate, to: targetRate)
        } catch {
            return try fallback.resample(samples, from: sourceRate, to: targetRate)
        }
    }
}

public actor AudioLevelMeter {
    private var metrics = AudioMetrics()

    public init() {}

    public func process(_ frame: AudioFrame) {
        guard !frame.samples.isEmpty else { return }
        var sum: Float = 0
        var peak: Float = 0
        for sample in frame.samples {
            let magnitude = abs(sample)
            sum += sample * sample
            peak = max(peak, magnitude)
        }
        metrics.peak = peak
        metrics.rms = sqrt(sum / Float(frame.samples.count))
        metrics.clipping = peak >= 0.99
    }

    public func snapshot(overruns: Int = 0, droppedFrames: Int = 0) -> AudioMetrics {
        var result = metrics
        result.ringBufferOverruns = overruns
        result.droppedFrames = droppedFrames
        return result
    }
}
