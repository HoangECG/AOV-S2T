import Foundation

/// Test-only translator; it is never chosen as the application's production
/// translation dependency.
public actor MockTranslationEngine: TranslationEngine {
    public var availabilityResult: TranslationAvailability
    public var results: [TranslationResult]
    public private(set) var requests: [String] = []
    public private(set) var wasCancelled = false

    public init(availability: TranslationAvailability = .installed, results: [TranslationResult] = []) {
        availabilityResult = availability
        self.results = results
    }

    public func availability(source: TranslationLanguage, target: TranslationLanguage) async -> TranslationAvailability {
        availabilityResult
    }

    public func translate(text: String, source: TranslationLanguage, target: TranslationLanguage, context: TranslationContext) async throws -> TranslationResult {
        requests.append(text)
        guard case .installed = availabilityResult else {
            throw MacSpeechTranslatorError.translationUnavailable("Mock translation pair is unavailable.")
        }
        return results.isEmpty ? TranslationResult(text: "[\(target.rawValue)] \(text)") : results.removeFirst()
    }

    public func cancelCurrentTranslation() async { wasCancelled = true }
}
