import Foundation
import MacSpeechTranslatorCore

@MainActor
struct AppDependencies {
    let audioDeviceProvider: any AudioDeviceProviding
    let systemAudioSourceProvider: any SystemAudioSourceProviding
    let makeModelManager: () throws -> ASRModelManager
    let makeTranscriptRepository: () throws -> any TranscriptRepository
    let makeAudioRepository: () throws -> any AudioRecordingRepository
    let makeGlossaryRepository: () throws -> any GlossaryRepository
    let makeWhisperEngine: () -> WhisperCppEngine
    let makeTranslationEngine: () -> any TranslationEngine
    let makeSubtitleOverlayServer: () -> LocalSubtitleOverlayServer

    static let live = AppDependencies(
        audioDeviceProvider: AudioDeviceManager(),
        systemAudioSourceProvider: SystemAudioSourceProvider(),
        makeModelManager: { try ASRModelManager() },
        makeTranscriptRepository: { try SQLiteTranscriptRepository() },
        makeAudioRepository: { try FileAudioRecordingRepository() },
        makeGlossaryRepository: { GlossaryPreferencesRepository() },
        makeWhisperEngine: { WhisperCppEngine() },
        makeTranslationEngine: { AppleTranslationEngine() },
        makeSubtitleOverlayServer: { LocalSubtitleOverlayServer() }
    )
}
