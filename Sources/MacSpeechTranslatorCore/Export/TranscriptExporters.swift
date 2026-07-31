import Foundation

public enum TimestampFormatter {
    public static func srt(_ time: TimeInterval) -> String {
        formatted(time, separator: ",")
    }

    public static func vtt(_ time: TimeInterval) -> String {
        formatted(time, separator: ".")
    }

    private static func formatted(_ time: TimeInterval, separator: String) -> String {
        let milliseconds = max(0, Int((time * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator, remainder)
    }
}

public struct TXTExporter: TranscriptExporting {
    public let format: TranscriptExportFormat = .text
    public init() {}

    public func export(session: TranscriptionSession, segments: [TranscriptSegment], bilingual: Bool) throws -> Data {
        let body = orderedSegments(segments).map { segment in
            guard bilingual, let translation = segment.translatedText, !translation.isEmpty else { return segment.preferredText }
            return "\(segment.preferredText)\n\(translation)"
        }.joined(separator: "\n\n")
        return try utf8Data(body)
    }
}

public struct JSONExporter: TranscriptExporting {
    public let format: TranscriptExportFormat = .json
    public init() {}

    public func export(session: TranscriptionSession, segments: [TranscriptSegment], bilingual: Bool) throws -> Data {
        let document = JSONExportDocument(session: session, segments: orderedSegments(segments), bilingual: bilingual)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }
}

public struct SRTExporter: TranscriptExporting {
    public let format: TranscriptExportFormat = .srt
    public init() {}

    public func export(session: TranscriptionSession, segments: [TranscriptSegment], bilingual: Bool) throws -> Data {
        let cues = validCues(from: segments)
        let output = cues.enumerated().map { index, cue in
            "\(index + 1)\n\(TimestampFormatter.srt(cue.start)) --> \(TimestampFormatter.srt(cue.end))\n\(cueText(cue.segment, bilingual: bilingual))"
        }.joined(separator: "\n\n")
        return try utf8Data(output.isEmpty ? "" : output + "\n")
    }
}

public struct VTTExporter: TranscriptExporting {
    public let format: TranscriptExportFormat = .vtt
    public init() {}

    public func export(session: TranscriptionSession, segments: [TranscriptSegment], bilingual: Bool) throws -> Data {
        let cues = validCues(from: segments)
        let body = cues.map { cue in
            "\(TimestampFormatter.vtt(cue.start)) --> \(TimestampFormatter.vtt(cue.end))\n\(cueText(cue.segment, bilingual: bilingual))"
        }.joined(separator: "\n\n")
        return try utf8Data("WEBVTT\n\n" + body + (body.isEmpty ? "" : "\n"))
    }
}

public enum TranscriptExporterFactory {
    public static func make(format: TranscriptExportFormat) -> any TranscriptExporting {
        switch format {
        case .text: TXTExporter()
        case .json: JSONExporter()
        case .srt: SRTExporter()
        case .vtt: VTTExporter()
        }
    }
}

private struct JSONExportDocument: Codable {
    let session: TranscriptionSession
    let segments: [TranscriptSegment]
    let bilingual: Bool
}

private struct ExportCue {
    let segment: TranscriptSegment
    let start: TimeInterval
    let end: TimeInterval
}

private func orderedSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
    segments.filter(\.isFinal).sorted { lhs, rhs in
        if lhs.startTime == rhs.startTime { return lhs.createdAt < rhs.createdAt }
        return lhs.startTime < rhs.startTime
    }
}

private func validCues(from segments: [TranscriptSegment]) -> [ExportCue] {
    var lastEnd: TimeInterval = 0
    return orderedSegments(segments).map { segment in
        let start = max(segment.startTime, lastEnd)
        let end = max(segment.endTime, start + 0.001)
        lastEnd = end
        return ExportCue(segment: segment, start: start, end: end)
    }
}

private func cueText(_ segment: TranscriptSegment, bilingual: Bool) -> String {
    guard bilingual, let translation = segment.translatedText, !translation.isEmpty else { return segment.preferredText }
    return "\(segment.preferredText)\n\(translation)"
}

private func utf8Data(_ string: String) throws -> Data {
    guard let data = string.data(using: .utf8) else {
        throw MacSpeechTranslatorError.exportFailed("Could not encode export as UTF-8.")
    }
    return data
}
