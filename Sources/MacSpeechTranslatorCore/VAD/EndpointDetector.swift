import Foundation

public enum EndpointDecision: Sendable, Equatable {
    case keepListening
    case finalize(reason: String)
    case discardShortUtterance
}

/// Endpointing combines VAD silence, transcript stability/punctuation, and a
/// hard maximum duration. It deliberately does not rely on VAD alone.
public actor EndpointDetector {
    private let configuration: EndpointConfiguration
    private var utteranceStartedAt: TimeInterval?
    private var silenceStartedAt: TimeInterval?

    public init(configuration: EndpointConfiguration = EndpointConfiguration()) {
        self.configuration = configuration
    }

    public func reset() {
        utteranceStartedAt = nil
        silenceStartedAt = nil
    }

    public func evaluate(
        vad: VADResult,
        partial: StabilizedTranscript?,
        utteranceStartedAt startTime: TimeInterval
    ) -> EndpointDecision {
        if utteranceStartedAt == nil { utteranceStartedAt = startTime }
        let duration = max(0, vad.timestamp - startTime)
        guard duration >= configuration.minimumSpeechDuration else { return .keepListening }
        if duration >= configuration.maximumWait { return .finalize(reason: "maximum utterance duration") }

        if vad.isSpeech {
            silenceStartedAt = nil
            return .keepListening
        }
        if silenceStartedAt == nil { silenceStartedAt = vad.timestamp }
        guard let silenceStartedAt else { return .keepListening }
        let silenceDuration = vad.timestamp - silenceStartedAt
        let text = partial?.displayText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endsWithPunctuation = text.last.map { ".?!".contains($0) } ?? false
        let isStable = !(partial?.unstableSuffix.isEmpty == false)

        if endsWithPunctuation && silenceDuration >= configuration.punctuationSilence {
            return .finalize(reason: "punctuation and silence")
        }
        if !text.isEmpty && isStable && silenceDuration >= configuration.stableSilence {
            return .finalize(reason: "stable transcript and silence")
        }
        if text.isEmpty && silenceDuration >= configuration.stableSilence {
            return .discardShortUtterance
        }
        return .keepListening
    }
}
