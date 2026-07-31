import Foundation

public enum AudioSourceType: String, Codable, CaseIterable, Sendable, Identifiable {
    case microphone
    case systemAudio

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .microphone: "Microphone / soundcard"
        case .systemAudio: "System audio"
        }
    }
}

public enum AudioInputState: Sendable, Equatable {
    case idle
    case prepared
    case recording
    case paused
    case stopped
    case permissionDenied
    case unavailable(String)
    case failed(String)

    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .prepared: "Ready"
        case .recording: "Capturing"
        case .paused: "Paused"
        case .stopped: "Stopped"
        case .permissionDenied: "Permission denied"
        case .unavailable(let message), .failed(let message): message
        }
    }
}

public struct AudioInputDevice: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let sampleRate: Double
    public let channelCount: Int
    public let isDefault: Bool

    public init(
        id: String,
        name: String,
        sampleRate: Double,
        channelCount: Int,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isDefault = isDefault
    }
}

public enum AudioChannelSelection: Codable, Hashable, Sendable {
    case downmix
    case channel(Int)

    public var displayName: String {
        switch self {
        case .downmix: "Downmix to mono"
        case .channel(let index): "Channel \(index + 1)"
        }
    }
}

public struct AudioInputConfiguration: Codable, Hashable, Sendable {
    public var source: AudioSourceType
    public var deviceID: String?
    public var channelSelection: AudioChannelSelection
    public var preferredSampleRate: Double
    public var processingFrameMilliseconds: Int
    public var systemAudioSourceID: String?

    public init(
        source: AudioSourceType = .microphone,
        deviceID: String? = nil,
        channelSelection: AudioChannelSelection = .downmix,
        preferredSampleRate: Double = 48_000,
        processingFrameMilliseconds: Int = 20,
        systemAudioSourceID: String? = nil
    ) {
        self.source = source
        self.deviceID = deviceID
        self.channelSelection = channelSelection
        self.preferredSampleRate = preferredSampleRate
        self.processingFrameMilliseconds = processingFrameMilliseconds
        self.systemAudioSourceID = systemAudioSourceID
    }
}

public enum SystemAudioSourceKind: String, Codable, Sendable {
    case display
    case application
}

public struct SystemAudioSource: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: SystemAudioSourceKind

    public init(id: String, displayName: String, kind: SystemAudioSourceKind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

public struct AudioFrame: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Int
    public let channelCount: Int
    /// Session-relative start time for transcript/export timestamps.
    public let timestamp: TimeInterval
    /// Monotonic capture completion time used only for live latency metrics.
    /// It is never persisted or exported.
    public let captureEndUptime: TimeInterval?

    public init(
        samples: [Float],
        sampleRate: Int,
        channelCount: Int,
        timestamp: TimeInterval,
        captureEndUptime: TimeInterval? = nil
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = max(channelCount, 1)
        self.timestamp = timestamp
        self.captureEndUptime = captureEndUptime
    }

    public var frameCount: Int { samples.count / channelCount }
    public var duration: TimeInterval { Double(frameCount) / Double(max(sampleRate, 1)) }
}

public struct AudioMetrics: Sendable, Equatable {
    public var peak: Float
    public var rms: Float
    public var clipping: Bool
    public var ringBufferOverruns: Int
    public var droppedFrames: Int

    public init(peak: Float = 0, rms: Float = 0, clipping: Bool = false, ringBufferOverruns: Int = 0, droppedFrames: Int = 0) {
        self.peak = peak
        self.rms = rms
        self.clipping = clipping
        self.ringBufferOverruns = ringBufferOverruns
        self.droppedFrames = droppedFrames
    }
}

/// Cheap capture-side diagnostics read from the source's bounded ring buffer.
/// These values contain no audio content and are safe to surface in the UI.
public struct AudioCaptureMetrics: Sendable, Equatable {
    public var ringBufferOverruns: Int
    public var ringBufferUnderruns: Int
    public var droppedFrames: Int
    public var droppedSamples: Int

    public init(
        ringBufferOverruns: Int = 0,
        ringBufferUnderruns: Int = 0,
        droppedFrames: Int = 0,
        droppedSamples: Int = 0
    ) {
        self.ringBufferOverruns = ringBufferOverruns
        self.ringBufferUnderruns = ringBufferUnderruns
        self.droppedFrames = droppedFrames
        self.droppedSamples = droppedSamples
    }
}

public enum VADState: String, Codable, CaseIterable, Sendable {
    case silence
    case possibleSpeech
    case speech
    case ending
}

public struct VADResult: Sendable, Equatable {
    public let state: VADState
    public let speechProbability: Float
    public let isSpeech: Bool
    public let timestamp: TimeInterval

    public init(state: VADState, speechProbability: Float, isSpeech: Bool, timestamp: TimeInterval) {
        self.state = state
        self.speechProbability = speechProbability
        self.isSpeech = isSpeech
        self.timestamp = timestamp
    }
}

public struct VADConfiguration: Codable, Hashable, Sendable {
    public var speechThreshold: Float
    public var releaseThreshold: Float
    public var minimumSpeechDuration: TimeInterval
    public var minimumSilenceDuration: TimeInterval
    public var maximumUtteranceDuration: TimeInterval
    public var adaptiveNoiseMultiplier: Float

    public init(
        speechThreshold: Float = 0.025,
        releaseThreshold: Float = 0.015,
        minimumSpeechDuration: TimeInterval = 0.25,
        minimumSilenceDuration: TimeInterval = 0.7,
        maximumUtteranceDuration: TimeInterval = 20,
        adaptiveNoiseMultiplier: Float = 2.5
    ) {
        self.speechThreshold = speechThreshold
        self.releaseThreshold = releaseThreshold
        self.minimumSpeechDuration = minimumSpeechDuration
        self.minimumSilenceDuration = minimumSilenceDuration
        self.maximumUtteranceDuration = maximumUtteranceDuration
        self.adaptiveNoiseMultiplier = adaptiveNoiseMultiplier
    }
}

public struct EndpointConfiguration: Codable, Hashable, Sendable {
    public var punctuationSilence: TimeInterval
    public var stableSilence: TimeInterval
    public var maximumWait: TimeInterval
    public var minimumSpeechDuration: TimeInterval

    public init(
        punctuationSilence: TimeInterval = 0.3,
        stableSilence: TimeInterval = 0.7,
        maximumWait: TimeInterval = 20,
        minimumSpeechDuration: TimeInterval = 0.25
    ) {
        self.punctuationSilence = punctuationSilence
        self.stableSilence = stableSilence
        self.maximumWait = maximumWait
        self.minimumSpeechDuration = minimumSpeechDuration
    }
}

public struct ASRConfiguration: Codable, Hashable, Sendable {
    public var languageCode: String
    public var temperature: Float
    public var initialPrompt: String
    public var wordTimestamps: Bool

    public init(languageCode: String = "vi", temperature: Float = 0, initialPrompt: String = "", wordTimestamps: Bool = true) {
        self.languageCode = languageCode
        self.temperature = temperature
        self.initialPrompt = initialPrompt
        self.wordTimestamps = wordTimestamps
    }
}

public struct ASRContext: Sendable, Equatable {
    public let sessionID: UUID
    public let utteranceID: UUID
    public let revision: Int
    public let prompt: String

    public init(sessionID: UUID, utteranceID: UUID, revision: Int, prompt: String = "") {
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.revision = revision
        self.prompt = prompt
    }
}

public struct ASRResult: Sendable, Equatable {
    public let text: String
    public let confidence: Float?
    public let processingTime: TimeInterval

    public init(text: String, confidence: Float? = nil, processingTime: TimeInterval = 0) {
        self.text = text
        self.confidence = confidence
        self.processingTime = processingTime
    }
}

public enum ASRModelState: Sendable, Equatable {
    case unloaded
    case loading
    case loaded(name: String)
    case unavailable(String)
    case failed(String)
}

public struct ASRModelDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let relativePath: String
    public let importedAt: Date

    public init(id: UUID = UUID(), displayName: String, relativePath: String, importedAt: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
        self.importedAt = importedAt
    }
}

public struct RealtimeConfiguration: Codable, Hashable, Sendable {
    public var partialInterval: TimeInterval
    public var rollingWindow: TimeInterval
    public var preRoll: TimeInterval
    public var finalSilence: TimeInterval
    public var maximumUtteranceDuration: TimeInterval
    public var minimumValidSpeech: TimeInterval

    public init(
        partialInterval: TimeInterval = 0.8,
        rollingWindow: TimeInterval = 6,
        preRoll: TimeInterval = 0.25,
        finalSilence: TimeInterval = 0.7,
        maximumUtteranceDuration: TimeInterval = 20,
        minimumValidSpeech: TimeInterval = 0.25
    ) {
        self.partialInterval = partialInterval
        self.rollingWindow = rollingWindow
        self.preRoll = preRoll
        self.finalSilence = finalSilence
        self.maximumUtteranceDuration = maximumUtteranceDuration
        self.minimumValidSpeech = minimumValidSpeech
    }
}

public enum TranscriptEventType: String, Codable, Sendable {
    case partial
    case final
    case error
}

public struct TranscriptEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let utteranceID: UUID
    public let revision: Int
    public let type: TranscriptEventType
    public let rawText: String
    public let normalizedText: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let createdAt: Date
    public let isFinal: Bool
    public let confidence: Float?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        utteranceID: UUID,
        revision: Int,
        type: TranscriptEventType,
        rawText: String,
        normalizedText: String = "",
        startTime: TimeInterval,
        endTime: TimeInterval,
        createdAt: Date = .now,
        isFinal: Bool,
        confidence: Float? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.revision = revision
        self.type = type
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.startTime = startTime
        self.endTime = max(endTime, startTime)
        self.createdAt = createdAt
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

/// Delivered after a final utterance is recognized so optional recording can
/// happen outside the audio callback and outside the ASR engine.
public struct FinalUtteranceAudio: Sendable, Equatable {
    public let sessionID: UUID
    public let utteranceID: UUID
    public let samples: [Float]
    public let sampleRate: Int

    public init(sessionID: UUID, utteranceID: UUID, samples: [Float], sampleRate: Int = 16_000) {
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public enum QualityLabel: String, Codable, CaseIterable, Sendable {
    case unreviewed
    case approved
    case incorrect
}

public struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let sessionID: UUID
    public let utteranceID: UUID
    public let revision: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public let rawText: String
    public var normalizedText: String
    public var correctedText: String?
    public var translatedText: String?
    public let isFinal: Bool
    public let confidence: Float?
    public let createdAt: Date
    public var audioFileRelativePath: String?
    public var qualityLabel: QualityLabel
    public var glossaryVersion: Int

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        utteranceID: UUID,
        revision: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        rawText: String,
        normalizedText: String,
        correctedText: String? = nil,
        translatedText: String? = nil,
        isFinal: Bool = true,
        confidence: Float? = nil,
        createdAt: Date = .now,
        audioFileRelativePath: String? = nil,
        qualityLabel: QualityLabel = .unreviewed,
        glossaryVersion: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.revision = revision
        self.startTime = startTime
        self.endTime = max(endTime, startTime)
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.correctedText = correctedText
        self.translatedText = translatedText
        self.isFinal = isFinal
        self.confidence = confidence
        self.createdAt = createdAt
        self.audioFileRelativePath = audioFileRelativePath
        self.qualityLabel = qualityLabel
        self.glossaryVersion = glossaryVersion
    }

    public var preferredText: String {
        guard let correctedText, !correctedText.isEmpty else { return normalizedText }
        return correctedText
    }
}

public struct TranscriptionSession: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var endedAt: Date?
    public let audioSourceType: AudioSourceType
    public let inputDeviceName: String?
    public let asrModelName: String?
    public let sourceLanguage: String
    public let targetLanguage: String
    public let appVersion: String
    public var notes: String

    public init(
        id: UUID = UUID(),
        title: String = "New session",
        createdAt: Date = .now,
        endedAt: Date? = nil,
        audioSourceType: AudioSourceType,
        inputDeviceName: String? = nil,
        asrModelName: String? = nil,
        sourceLanguage: String = "vi",
        targetLanguage: String = "en",
        appVersion: String = "0.1.0",
        notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.audioSourceType = audioSourceType
        self.inputDeviceName = inputDeviceName
        self.asrModelName = asrModelName
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.appVersion = appVersion
        self.notes = notes
    }
}

public struct GlossaryEntry: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var spokenForms: [String]
    public var canonicalText: String
    public var targetTranslations: [String: String]
    public var enabled: Bool
    public var caseSensitive: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        spokenForms: [String],
        canonicalText: String,
        targetTranslations: [String: String] = [:],
        enabled: Bool = true,
        caseSensitive: Bool = false,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.spokenForms = spokenForms
        self.canonicalText = canonicalText
        self.targetTranslations = targetTranslations
        self.enabled = enabled
        self.caseSensitive = caseSensitive
        self.updatedAt = updatedAt
    }
}

public struct TranslationLanguage: RawRepresentable, Codable, Hashable, Sendable, Identifiable, ExpressibleByStringLiteral {
    public let rawValue: String
    public var id: String { rawValue }

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let vietnamese: Self = "vi"
    public static let english: Self = "en"
    public static let japanese: Self = "ja"
    public static let korean: Self = "ko"

    public var displayName: String {
        Locale.current.localizedString(forLanguageCode: rawValue) ?? rawValue
    }
}

public enum TranslationAvailability: Sendable, Equatable {
    case installed
    case requiresDownload
    case unsupported
    case unavailable(String)
}

public struct TranslationContext: Sendable, Equatable {
    public let sessionID: UUID
    public let segmentID: UUID
    public let glossaryVersion: Int

    public init(sessionID: UUID, segmentID: UUID, glossaryVersion: Int = 0) {
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.glossaryVersion = glossaryVersion
    }
}

public struct TranslationResult: Sendable, Equatable {
    public let text: String
    public let processingTime: TimeInterval

    public init(text: String, processingTime: TimeInterval = 0) {
        self.text = text
        self.processingTime = processingTime
    }
}

public struct ASRMetrics: Codable, Sendable, Equatable {
    public var inputDuration: TimeInterval
    public var processingDuration: TimeInterval
    public var partialLatency: TimeInterval?
    public var finalLatency: TimeInterval?
    public var emptyResultCount: Int
    public var droppedUtteranceCount: Int

    public init(
        inputDuration: TimeInterval = 0,
        processingDuration: TimeInterval = 0,
        partialLatency: TimeInterval? = nil,
        finalLatency: TimeInterval? = nil,
        emptyResultCount: Int = 0,
        droppedUtteranceCount: Int = 0
    ) {
        self.inputDuration = inputDuration
        self.processingDuration = processingDuration
        self.partialLatency = partialLatency
        self.finalLatency = finalLatency
        self.emptyResultCount = emptyResultCount
        self.droppedUtteranceCount = droppedUtteranceCount
    }

    public var realtimeFactor: Double {
        guard inputDuration > 0 else { return 0 }
        return processingDuration / inputDuration
    }
}

public enum MacSpeechTranslatorError: LocalizedError, Sendable, Equatable {
    case microphonePermissionDenied
    case screenCapturePermissionDenied
    case deviceNotFound
    case deviceDisconnected
    case invalidAudioFormat
    case modelMissing
    case invalidModel(String)
    case asrUnavailable(String)
    case translationUnavailable(String)
    case exportFailed(String)
    case storageFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "Microphone permission was denied."
        case .screenCapturePermissionDenied: "Screen Recording permission was denied."
        case .deviceNotFound: "The selected audio input device was not found."
        case .deviceDisconnected: "The selected audio input device was disconnected."
        case .invalidAudioFormat: "The audio format is not supported."
        case .modelMissing: "No ASR model is selected."
        case .invalidModel(let message), .asrUnavailable(let message), .translationUnavailable(let message), .exportFailed(let message), .storageFailed(let message): message
        }
    }
}
