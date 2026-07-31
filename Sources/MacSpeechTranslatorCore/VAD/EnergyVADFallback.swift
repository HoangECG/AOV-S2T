import Foundation

/// Adaptive RMS VAD used when an optional Silero model is not installed.
/// It is intentionally labelled as a fallback because music and high noise can
/// produce false positives compared with a trained neural VAD.
public actor EnergyVADFallback: VoiceActivityDetecting {
    private let configuration: VADConfiguration
    private var state: VADState = .silence
    private var noiseFloor: Float = 0.003
    private var candidateSpeechStartedAt: TimeInterval?
    private var speechStartedAt: TimeInterval?
    private var silenceStartedAt: TimeInterval?

    public init(configuration: VADConfiguration = VADConfiguration()) {
        self.configuration = configuration
    }

    public func reset() {
        state = .silence
        candidateSpeechStartedAt = nil
        speechStartedAt = nil
        silenceStartedAt = nil
    }

    public func process(frame: AudioFrame) async throws -> VADResult {
        let rms = Self.rms(frame.samples)
        let timestamp = frame.timestamp + frame.duration
        let speechThreshold = max(configuration.speechThreshold, noiseFloor * configuration.adaptiveNoiseMultiplier)
        let releaseThreshold = max(configuration.releaseThreshold, noiseFloor * 1.5)
        let probability = min(max((rms - noiseFloor) / max(speechThreshold - noiseFloor, 0.0001), 0), 1)

        switch state {
        case .silence:
            updateNoiseFloor(with: rms)
            if rms >= speechThreshold {
                state = .possibleSpeech
                candidateSpeechStartedAt = frame.timestamp
            }
        case .possibleSpeech:
            if rms < releaseThreshold {
                state = .silence
                candidateSpeechStartedAt = nil
                updateNoiseFloor(with: rms)
            } else if let candidateSpeechStartedAt,
                      timestamp - candidateSpeechStartedAt >= configuration.minimumSpeechDuration {
                state = .speech
                speechStartedAt = candidateSpeechStartedAt
                silenceStartedAt = nil
            }
        case .speech:
            if rms < releaseThreshold {
                state = .ending
                silenceStartedAt = frame.timestamp
            }
        case .ending:
            if rms >= speechThreshold {
                state = .speech
                silenceStartedAt = nil
            } else if let silenceStartedAt,
                      timestamp - silenceStartedAt >= configuration.minimumSilenceDuration {
                state = .silence
                candidateSpeechStartedAt = nil
                speechStartedAt = nil
                self.silenceStartedAt = nil
                updateNoiseFloor(with: rms)
            }
        }

        return VADResult(
            state: state,
            speechProbability: probability,
            isSpeech: state == .speech || state == .possibleSpeech,
            timestamp: timestamp
        )
    }

    private func updateNoiseFloor(with rms: Float) {
        noiseFloor = max(0.00001, noiseFloor * 0.98 + rms * 0.02)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return sqrt(sum / Float(samples.count))
    }
}
