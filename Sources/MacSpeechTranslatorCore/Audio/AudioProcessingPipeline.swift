import Foundation

/// Converts captured native frames into the ASR's 16 kHz mono Float32 format.
/// Call this from the processing task, not an audio callback.
public struct AudioProcessingPipeline: Sendable {
    private let resampler: any AudioResampling
    private let targetSampleRate: Int

    public init(resampler: any AudioResampling = PreferredAudioResampler(), targetSampleRate: Int = 16_000) {
        self.resampler = resampler
        self.targetSampleRate = targetSampleRate
    }

    public func process(_ frame: AudioFrame, selection: AudioChannelSelection) throws -> AudioFrame {
        let mono = AudioChannelMixer.mixToMono(frame.samples, channelCount: frame.channelCount, selection: selection)
        let resampled = try resampler.resample(mono, from: frame.sampleRate, to: targetSampleRate)
        return AudioFrame(
            samples: resampled,
            sampleRate: targetSampleRate,
            channelCount: 1,
            timestamp: frame.timestamp,
            captureEndUptime: frame.captureEndUptime
        )
    }
}

public actor PreRollAudioBuffer {
    private let maximumDuration: TimeInterval
    private var samples: [Float] = []
    private var sampleRate = 16_000

    public init(maximumDuration: TimeInterval = 0.25) {
        self.maximumDuration = maximumDuration
    }

    public func append(_ frame: AudioFrame) {
        guard frame.channelCount == 1 else { return }
        if sampleRate != frame.sampleRate {
            samples.removeAll(keepingCapacity: true)
            sampleRate = frame.sampleRate
        }
        samples.append(contentsOf: frame.samples)
        let maximumSamples = Int(maximumDuration * Double(sampleRate))
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    public func snapshot() -> [Float] { samples }

    public func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
