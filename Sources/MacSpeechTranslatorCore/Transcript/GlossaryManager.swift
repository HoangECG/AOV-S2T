import Foundation

public actor GlossaryManager {
    private var entries: [GlossaryEntry]
    private var currentVersion = 0

    public init(entries: [GlossaryEntry] = []) {
        self.entries = entries
    }

    public func allEntries() -> [GlossaryEntry] { entries }
    public func version() -> Int { currentVersion }

    public func replaceEntries(_ entries: [GlossaryEntry]) {
        self.entries = entries
        currentVersion += 1
    }

    public func upsert(_ entry: GlossaryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        currentVersion += 1
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        currentVersion += 1
    }

    public func hotwordPrompt(maximumCharacters: Int = 300) -> String {
        var prompt = ""
        for entry in entries where entry.enabled {
            let candidate = entry.canonicalText
            let separated = prompt.isEmpty ? candidate : "\(prompt), \(candidate)"
            guard separated.count <= maximumCharacters else { break }
            prompt = separated
        }
        return prompt
    }

    public func applyCanonicalCorrections(to text: String) -> String {
        entries
            .filter(\.enabled)
            .sorted { $0.canonicalText.count > $1.canonicalText.count }
            .reduce(text) { partial, entry in
                entry.spokenForms.reduce(partial) { corrected, spokenForm in
                    replaceWholeOccurrence(of: spokenForm, with: entry.canonicalText, in: corrected, caseSensitive: entry.caseSensitive)
                }
            }
    }

    public func preferredTranslation(for canonicalText: String, target: TranslationLanguage) -> String? {
        entries.first(where: { $0.enabled && $0.canonicalText == canonicalText })?.targetTranslations[target.rawValue]
    }

    public func protect(text: String, target: TranslationLanguage) -> GlossaryProtectedText {
        var protectedText = text
        var replacements: [String: String] = [:]
        var index = 0
        for entry in entries where entry.enabled {
            guard let desiredTranslation = entry.targetTranslations[target.rawValue], !desiredTranslation.isEmpty else { continue }
            let placeholder = "[[MST_TERM_\(index)]]"
            let changed = replaceWholeOccurrence(of: entry.canonicalText, with: placeholder, in: protectedText, caseSensitive: entry.caseSensitive)
            if changed != protectedText {
                protectedText = changed
                replacements[placeholder] = desiredTranslation
                index += 1
            }
        }
        return GlossaryProtectedText(text: protectedText, replacements: replacements)
    }

    private func replaceWholeOccurrence(of source: String, with replacement: String, in text: String, caseSensitive: Bool) -> String {
        guard !source.isEmpty else { return text }
        var result = text
        var searchRange = result.startIndex..<result.endIndex
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        while let range = result.range(of: source, options: options, range: searchRange) {
            let previous = range.lowerBound > result.startIndex ? result[result.index(before: range.lowerBound)] : nil
            let next = range.upperBound < result.endIndex ? result[range.upperBound] : nil
            let hasWordBoundary = !(previous?.isLetter == true || previous?.isNumber == true)
                && !(next?.isLetter == true || next?.isNumber == true)
            if hasWordBoundary {
                result.replaceSubrange(range, with: replacement)
                searchRange = result.index(range.lowerBound, offsetBy: replacement.count)..<result.endIndex
            } else {
                searchRange = range.upperBound..<result.endIndex
            }
        }
        return result
    }
}

public struct GlossaryProtectedText: Sendable, Equatable {
    public let text: String
    public let replacements: [String: String]

    public init(text: String, replacements: [String: String]) {
        self.text = text
        self.replacements = replacements
    }

    public func restore(in translation: String) -> String {
        replacements.reduce(translation) { result, pair in
            result.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }
}
