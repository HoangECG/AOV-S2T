import Foundation

public protocol AudioInputSource: AnyObject, Sendable {
    var stateStream: AsyncStream<AudioInputState> { get }
    var audioStream: AsyncThrowingStream<AudioFrame, Error> { get }

    func prepare(configuration: AudioInputConfiguration) async throws
    func start() async throws
    func stop() async
    func captureMetrics() -> AudioCaptureMetrics
}

public protocol AudioDeviceProviding: Sendable {
    func inputDevices() async throws -> [AudioInputDevice]
    func defaultInputDevice() async throws -> AudioInputDevice?
}

public protocol SystemAudioSourceProviding: Sendable {
    func systemAudioSources() async throws -> [SystemAudioSource]
}

public protocol AudioResampling: Sendable {
    func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) throws -> [Float]
}

public protocol VoiceActivityDetecting: Sendable {
    func reset() async
    func process(frame: AudioFrame) async throws -> VADResult
}

public protocol ASREngine: Sendable {
    func loadModel(at url: URL, configuration: ASRConfiguration) async throws
    func transcribePartial(audio: [Float], sampleRate: Int, context: ASRContext) async throws -> ASRResult
    func transcribeFinal(audio: [Float], sampleRate: Int, context: ASRContext) async throws -> ASRResult
    func cancelCurrentInference() async
    func unloadModel() async
}

public protocol TranscriptStabilizing: Sendable {
    func reset(utteranceID: UUID) async
    func stabilize(_ text: String, utteranceID: UUID) async -> StabilizedTranscript
}

public protocol SentenceFinalizing: Sendable {
    func finalize(text: String, startTime: TimeInterval, endTime: TimeInterval) async -> [FinalizedSentence]
}

public protocol TextNormalizing: Sendable {
    func normalize(_ text: String) -> String
}

public protocol TranslationEngine: Sendable {
    func availability(source: TranslationLanguage, target: TranslationLanguage) async -> TranslationAvailability
    func translate(text: String, source: TranslationLanguage, target: TranslationLanguage, context: TranslationContext) async throws -> TranslationResult
    func cancelCurrentTranslation() async
}

public protocol TranscriptRepository: Sendable {
    func createSession(_ session: TranscriptionSession) async throws
    func sessions(query: String?) async throws -> [TranscriptionSession]
    func saveFinalSegment(_ segment: TranscriptSegment) async throws
    func segments(for sessionID: UUID) async throws -> [TranscriptSegment]
    func updateSegment(_ segment: TranscriptSegment) async throws
    func deleteSession(id: UUID) async throws
}

public protocol AudioRecordingRepository: Sendable {
    func saveUtterance(samples: [Float], sampleRate: Int, utteranceID: UUID) async throws -> String
    func loadUtterance(relativePath: String) async throws -> URL
    func deleteUtterance(relativePath: String) async throws
}

public protocol GlossaryRepository: Sendable {
    func entries() async throws -> [GlossaryEntry]
    func save(_ entries: [GlossaryEntry]) async throws
}

public enum TranscriptExportFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case text
    case json
    case srt
    case vtt

    public var id: String { rawValue }
}

public protocol TranscriptExporting: Sendable {
    var format: TranscriptExportFormat { get }
    func export(session: TranscriptionSession, segments: [TranscriptSegment], bilingual: Bool) throws -> Data
}

public struct StabilizedTranscript: Sendable, Equatable {
    public let revision: Int
    public let stablePrefix: String
    public let unstableSuffix: String
    public let displayText: String

    public init(revision: Int, stablePrefix: String, unstableSuffix: String) {
        self.revision = revision
        self.stablePrefix = stablePrefix
        self.unstableSuffix = unstableSuffix
        self.displayText = [stablePrefix, unstableSuffix].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct FinalizedSentence: Sendable, Equatable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = max(startTime, endTime)
    }
}
