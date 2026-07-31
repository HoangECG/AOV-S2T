import Foundation

public actor FileAudioRecordingRepository: AudioRecordingRepository {
    private let rootDirectory: URL
    private let fileManager: FileManager

    public init(rootDirectory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.rootDirectory = applicationSupport.appendingPathComponent("MacSpeechTranslator/Audio", isDirectory: true)
        }
        try fileManager.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    public func saveUtterance(samples: [Float], sampleRate: Int, utteranceID: UUID) throws -> String {
        let name = "utterance_\(utteranceID.uuidString).wav"
        let destination = rootDirectory.appendingPathComponent(name)
        try WAVWriter.write(samples: samples, sampleRate: sampleRate, to: destination)
        return name
    }

    public func loadUtterance(relativePath: String) throws -> URL {
        let url = try recordingURL(relativePath: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw MacSpeechTranslatorError.storageFailed("Recorded audio is unavailable.")
        }
        return url
    }

    public func deleteUtterance(relativePath: String) throws {
        let url = try recordingURL(relativePath: relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func recordingURL(relativePath: String) throws -> URL {
        let root = rootDirectory.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw MacSpeechTranslatorError.storageFailed("Recorded audio path is invalid.")
        }
        return candidate
    }
}
