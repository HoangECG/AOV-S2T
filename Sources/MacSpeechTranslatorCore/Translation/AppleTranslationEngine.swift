import Foundation
@preconcurrency import Translation

/// Uses only Apple Translation's locally installed language packs. macOS 15
/// can report availability; programmatic installed-session inference is
/// available from macOS 26, so older systems surface a clear unavailable state
/// instead of falling back to a cloud provider.
public actor AppleTranslationEngine: TranslationEngine {
    private var currentSession: AnyObject?

    public init() {}

    public func availability(source: TranslationLanguage, target: TranslationLanguage) async -> TranslationAvailability {
        guard #available(macOS 15.0, *) else {
            return .unavailable("Apple Translation requires macOS 15 or later.")
        }
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: Locale.Language(identifier: source.rawValue),
            to: Locale.Language(identifier: target.rawValue)
        )
        switch status {
        case .installed: return .installed
        case .supported: return .requiresDownload
        case .unsupported: return .unsupported
        @unknown default: return .unavailable("The selected translation pair has an unknown availability state.")
        }
    }

    public func translate(
        text: String,
        source: TranslationLanguage,
        target: TranslationLanguage,
        context: TranslationContext
    ) async throws -> TranslationResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return TranslationResult(text: "") }
        switch await availability(source: source, target: target) {
        case .installed:
            break
        case .requiresDownload:
            throw MacSpeechTranslatorError.translationUnavailable("The Apple Translation language pack must be downloaded in macOS settings before translating.")
        case .unsupported:
            throw MacSpeechTranslatorError.translationUnavailable("Apple Translation does not support the selected language pair.")
        case .unavailable(let message):
            throw MacSpeechTranslatorError.translationUnavailable(message)
        }

        guard #available(macOS 26.0, *) else {
            throw MacSpeechTranslatorError.translationUnavailable(
                "Programmatic Apple Translation is unavailable on this macOS release. Transcript capture remains local and operational."
            )
        }
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: source.rawValue),
            target: Locale.Language(identifier: target.rawValue)
        )
        currentSession = session
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            if currentSession === session { currentSession = nil }
        }
        let response = try await session.translate(text)
        return TranslationResult(
            text: response.targetText,
            processingTime: ProcessInfo.processInfo.systemUptime - startedAt
        )
    }

    public func cancelCurrentTranslation() async {
        if #available(macOS 26.0, *) {
            (currentSession as? TranslationSession)?.cancel()
            currentSession = nil
        }
    }
}
