import Foundation

public actor DatasetExporter {
    private let audioRepository: any AudioRecordingRepository
    private let fileManager: FileManager

    public init(audioRepository: any AudioRecordingRepository, fileManager: FileManager = .default) {
        self.audioRepository = audioRepository
        self.fileManager = fileManager
    }

    /// Exports only explicitly approved, recorded utterances. The caller owns
    /// the destination and should present the privacy warning before invoking.
    public func exportApproved(
        session: TranscriptionSession,
        segments: [TranscriptSegment],
        destination: URL
    ) async throws {
        let audioDirectory = destination.appendingPathComponent("audio", isDirectory: true)
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        var manifestLines: [String] = []

        let utteranceGroups = Dictionary(grouping: segments, by: \.utteranceID)
            .values
            .filter { group in
                !group.isEmpty
                    && group.allSatisfy { $0.qualityLabel == .approved && $0.audioFileRelativePath != nil }
            }
            .sorted { lhs, rhs in
                (lhs.map(\.startTime).min() ?? 0) < (rhs.map(\.startTime).min() ?? 0)
            }

        for group in utteranceGroups {
            let ordered = group.sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime { return lhs.createdAt < rhs.createdAt }
                return lhs.startTime < rhs.startTime
            }
            let paths = Set(ordered.compactMap(\.audioFileRelativePath))
            guard let relativePath = paths.first, paths.count == 1 else {
                throw MacSpeechTranslatorError.exportFailed("An approved utterance has inconsistent audio recordings.")
            }
            let sourceURL = try await audioRepository.loadUtterance(relativePath: relativePath)
            let fileName = "utterance_\(ordered[0].utteranceID.uuidString).wav"
            let destinationURL = audioDirectory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            let row = DatasetManifestRow(
                audioFilepath: "audio/\(fileName)",
                text: ordered.map(\.preferredText).joined(separator: " "),
                rawText: ordered[0].rawText,
                duration: max(0, (ordered.map(\.endTime).max() ?? 0) - (ordered.map(\.startTime).min() ?? 0)),
                sessionID: session.id.uuidString,
                language: session.sourceLanguage,
                device: session.inputDeviceName,
                model: session.asrModelName,
                qualityLabel: QualityLabel.approved.rawValue
            )
            let data = try JSONEncoder().encode(row)
            guard let line = String(data: data, encoding: .utf8) else {
                throw MacSpeechTranslatorError.exportFailed("Could not encode dataset manifest.")
            }
            manifestLines.append(line)
        }

        guard let manifestData = manifestLines.joined(separator: "\n").appending("\n").data(using: .utf8) else {
            throw MacSpeechTranslatorError.exportFailed("Could not encode dataset manifest.")
        }
        try manifestData.write(to: destination.appendingPathComponent("manifest.jsonl"), options: .atomic)
        let metadata = DatasetMetadata(sessionID: session.id.uuidString, createdAt: .now, approvedUtteranceCount: manifestLines.count)
        try JSONEncoder().encode(metadata).write(to: destination.appendingPathComponent("metadata.json"), options: .atomic)
    }
}

private struct DatasetManifestRow: Codable {
    let audioFilepath: String
    let text: String
    let rawText: String
    let duration: TimeInterval
    let sessionID: String
    let language: String
    let device: String?
    let model: String?
    let qualityLabel: String

    enum CodingKeys: String, CodingKey {
        case audioFilepath = "audio_filepath"
        case text
        case rawText = "raw_text"
        case duration
        case sessionID = "session_id"
        case language
        case device
        case model
        case qualityLabel = "quality_label"
    }
}

private struct DatasetMetadata: Codable {
    let sessionID: String
    let createdAt: Date
    let approvedUtteranceCount: Int
}
