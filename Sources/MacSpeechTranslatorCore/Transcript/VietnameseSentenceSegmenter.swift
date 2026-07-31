import Foundation

public struct VietnameseSentenceSegmenter: Sendable {
    public init() {}

    public func sentences(in text: String) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        var results: [String] = []
        var start = 0

        for index in characters.indices where ".?!".contains(characters[index]) {
            guard isBoundary(at: index, in: characters) else { continue }
            let sentence = String(characters[start...index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { results.append(sentence) }
            start = index + 1
        }
        let remainder = String(characters.dropFirst(start)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { results.append(remainder) }
        return results
    }

    private func isBoundary(at index: Int, in characters: [Character]) -> Bool {
        let punctuation = characters[index]
        if punctuation == "." {
            if (index > 0 && characters[index - 1] == ".") || (index + 1 < characters.count && characters[index + 1] == ".") {
                return false
            }
            if index > 0, index + 1 < characters.count, characters[index - 1].isNumber, characters[index + 1].isNumber {
                return false
            }
            let token = wordAround(index: index, in: characters)
            if token.contains("://") || token.contains("@") || isAbbreviation(token) || isVersionNumber(token) {
                return false
            }
        }
        return index + 1 == characters.count || characters[index + 1].isWhitespace
    }

    private func wordAround(index: Int, in characters: [Character]) -> String {
        var lower = index
        while lower > 0, !characters[lower - 1].isWhitespace { lower -= 1 }
        var upper = index
        while upper + 1 < characters.count, !characters[upper + 1].isWhitespace { upper += 1 }
        return String(characters[lower...upper])
    }

    private func isAbbreviation(_ token: String) -> Bool {
        // TP.HCM is an in-sentence geographic abbreviation, but a trailing
        // period after it can still terminate a sentence.
        if token == "TP.HCM." { return false }
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let common = ["TP", "TP.HCM", "PGS", "TS", "PGS.TS", "ThS", "GS", "Dr", "Mr", "Mrs", "vs"]
        if common.contains(trimmed) { return true }
        let parts = trimmed.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy { part in
            (1...4).contains(part.count) && part.allSatisfy { $0.isUppercase }
        }
    }

    private func isVersionNumber(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}
