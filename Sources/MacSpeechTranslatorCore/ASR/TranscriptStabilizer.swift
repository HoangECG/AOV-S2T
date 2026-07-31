import Foundation

/// Uses consensus across rolling ASR revisions rather than concatenating text.
/// The stable prefix is only the word sequence shared by recent revisions.
public actor RollingTranscriptStabilizer: TranscriptStabilizing {
    private var activeUtteranceID: UUID?
    private var revision = 0
    private var history: [[String]] = []

    public init() {}

    public func reset(utteranceID: UUID) {
        activeUtteranceID = utteranceID
        revision = 0
        history.removeAll(keepingCapacity: true)
    }

    public func stabilize(_ text: String, utteranceID: UUID) -> StabilizedTranscript {
        if activeUtteranceID != utteranceID {
            activeUtteranceID = utteranceID
            revision = 0
            history.removeAll(keepingCapacity: true)
        }
        revision += 1
        let tokens = Self.tokens(from: text)
        let deduplicatedTokens = Self.removeAdjacentRepeatedPhrase(tokens)

        let stableCount: Int
        if history.count >= 2 {
            stableCount = Self.commonPrefixLength(history[history.count - 2], history[history.count - 1], deduplicatedTokens)
        } else if let previous = history.last {
            stableCount = Self.commonPrefixLength(previous, deduplicatedTokens)
        } else {
            stableCount = 0
        }
        history.append(deduplicatedTokens)
        if history.count > 3 { history.removeFirst() }

        let stablePrefix = deduplicatedTokens.prefix(stableCount).joined(separator: " ")
        let unstableSuffix = deduplicatedTokens.dropFirst(stableCount).joined(separator: " ")
        return StabilizedTranscript(revision: revision, stablePrefix: stablePrefix, unstableSuffix: unstableSuffix)
    }

    private static func tokens(from text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private static func commonPrefixLength(_ first: [String], _ second: [String]) -> Int {
        var index = 0
        while index < first.count, index < second.count,
              first[index].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                == second[index].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) {
            index += 1
        }
        return index
    }

    private static func commonPrefixLength(_ first: [String], _ second: [String], _ third: [String]) -> Int {
        min(commonPrefixLength(first, second), commonPrefixLength(second, third))
    }

    private static func removeAdjacentRepeatedPhrase(_ tokens: [String]) -> [String] {
        guard tokens.count > 1 else { return tokens }
        var result: [String] = []
        for token in tokens {
            if result.last?.caseInsensitiveCompare(token) == .orderedSame { continue }
            result.append(token)
        }
        return result
    }
}
