import Foundation

/// Reserved integration boundary for a separately distributed Silero model.
/// No model binary is bundled or silently substituted in the production path.
public actor SileroVADAdapter: VoiceActivityDetecting {
    public init() {}

    public func reset() async {}

    public func process(frame: AudioFrame) async throws -> VADResult {
        throw MacSpeechTranslatorError.asrUnavailable(
            "Silero VAD is not installed. The app is using Energy VAD fallback when selected."
        )
    }
}
