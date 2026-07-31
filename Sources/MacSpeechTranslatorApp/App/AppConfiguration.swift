import Foundation
import MacSpeechTranslatorCore

enum AppConfiguration {
    static let supportedTargetLanguages: [TranslationLanguage] = [
        .english,
        .japanese,
        .korean
    ]
    static let appVersion = "0.1.0"
}
