import Foundation
import OSLog

public actor TranslationCoordinator {
    private let engine: any TranslationEngine
    private let glossary: GlossaryManager?
    private var cache: [CacheKey: String] = [:]
    private var translatedSegmentIDs = Set<UUID>()
    private var previousOperation: Task<TranslationResult, Error>?

    public init(engine: any TranslationEngine, glossary: GlossaryManager? = nil) {
        self.engine = engine
        self.glossary = glossary
    }

    /// Queues final sentences in arrival order. Partial revisions and an
    /// already-translated final segment are intentionally ignored.
    public func translateFinal(
        segment: TranscriptSegment,
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> TranslationResult? {
        guard segment.isFinal, !translatedSegmentIDs.contains(segment.id) else { return nil }
        let sourceText = segment.preferredText
        guard !sourceText.isEmpty else { return nil }
        let glossaryVersion = await glossary?.version() ?? 0
        let cacheKey = CacheKey(text: sourceText, source: source.rawValue, target: target.rawValue, glossaryVersion: glossaryVersion)
        if let cached = cache[cacheKey] {
            translatedSegmentIDs.insert(segment.id)
            return TranslationResult(text: cached)
        }
        translatedSegmentIDs.insert(segment.id)
        let context = TranslationContext(sessionID: segment.sessionID, segmentID: segment.id, glossaryVersion: glossaryVersion)
        let prior = previousOperation
        let engine = engine
        let protected = await glossary?.protect(text: sourceText, target: target) ?? GlossaryProtectedText(text: sourceText, replacements: [:])
        let operation = Task<TranslationResult, Error> {
            if let prior { _ = try? await prior.value }
            return try await engine.translate(text: protected.text, source: source, target: target, context: context)
        }
        previousOperation = operation
        do {
            let translated = try await operation.value
            let restored = protected.restore(in: translated.text)
            cache[cacheKey] = restored
            return TranslationResult(text: restored, processingTime: translated.processingTime)
        } catch {
            translatedSegmentIDs.remove(segment.id)
            DiagnosticsLogger.translation.error("Final-only translation failed.")
            throw error
        }
    }

    public func cancelAll() async {
        previousOperation?.cancel()
        previousOperation = nil
        await engine.cancelCurrentTranslation()
    }

    public func clearCache() {
        cache.removeAll()
    }
}

private struct CacheKey: Hashable, Sendable {
    let text: String
    let source: String
    let target: String
    let glossaryVersion: Int
}
