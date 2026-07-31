import Foundation

public struct VietnameseTextNormalizer: TextNormalizing {
    public init() {}

    public func normalize(_ text: String) -> String {
        var result = text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !result.isEmpty else { return "" }

        result = result.replacingOccurrences(
            of: "\\s+([,.;:!?])",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?i)(\\d+)\\s+phần\\s+trăm\\b",
            with: "$1%",
            options: .regularExpression
        )
        result = insertMissingSpaces(afterPunctuationIn: result)
        result = uppercaseFirstCharacter(in: result)
        if let last = result.last, last.isLetter || last.isNumber || last == "%" {
            result.append(".")
        }
        return result
    }

    private func insertMissingSpaces(afterPunctuationIn text: String) -> String {
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(text.count + 8)
        for index in characters.indices {
            let character = characters[index]
            output.append(character)
            guard ",;:?!".contains(character), index + 1 < characters.count else { continue }
            let next = characters[index + 1]
            guard !next.isWhitespace else { continue }
            if character == ":", next == "/" { continue }
            if character == ":", index > 0, characters[index - 1].isNumber, next.isNumber { continue }
            output.append(" ")
        }
        return output
    }

    private func uppercaseFirstCharacter(in text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + String(text.dropFirst())
    }
}
