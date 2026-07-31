import Foundation

/// Manages user-imported model files under Application Support. Model weights
/// are deliberately never bundled with or downloaded by the application.
public actor ASRModelManager {
    private let fileManager: FileManager
    private let modelsDirectory: URL
    private let preferences: UserDefaults
    private let selectedModelKey = "selectedASRModelID"
    private var descriptors: [ASRModelDescriptor] = []

    public init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil,
        preferences: UserDefaults = .standard
    ) throws {
        let root: URL
        if let applicationSupportDirectory {
            root = applicationSupportDirectory
        } else {
            root = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let directory = root.appendingPathComponent("MacSpeechTranslator/Models", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileManager = fileManager
        self.preferences = preferences
        self.modelsDirectory = directory
        self.descriptors = try Self.readDescriptors(from: directory, fileManager: fileManager)
    }

    public func models() -> [ASRModelDescriptor] {
        descriptors.sorted { $0.importedAt > $1.importedAt }
    }

    public func selectedModel() -> ASRModelDescriptor? {
        guard let idText = preferences.string(forKey: selectedModelKey), let id = UUID(uuidString: idText) else { return nil }
        return descriptors.first { $0.id == id }
    }

    public func select(modelID: UUID?) {
        if let modelID {
            preferences.set(modelID.uuidString, forKey: selectedModelKey)
        } else {
            preferences.removeObject(forKey: selectedModelKey)
        }
    }

    public func importModel(from sourceURL: URL, displayName: String? = nil) throws -> ASRModelDescriptor {
        guard fileManager.fileExists(atPath: sourceURL.path), fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw MacSpeechTranslatorError.invalidModel("The selected model file cannot be read.")
        }
        let extensionName = sourceURL.pathExtension.lowercased()
        guard ["gguf", "bin"].contains(extensionName) else {
            throw MacSpeechTranslatorError.invalidModel("Expected a whisper.cpp GGUF model (or a legacy .bin model supported by the configured CLI).")
        }

        let identifier = UUID()
        let fileName = "\(identifier.uuidString).\(extensionName)"
        let destinationURL = modelsDirectory.appendingPathComponent(fileName)
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw MacSpeechTranslatorError.invalidModel("Could not import the model: \(error.localizedDescription)")
        }
        let descriptor = ASRModelDescriptor(
            id: identifier,
            displayName: displayName ?? sourceURL.deletingPathExtension().lastPathComponent,
            relativePath: fileName
        )
        descriptors.append(descriptor)
        try persistDescriptors()
        select(modelID: identifier)
        return descriptor
    }

    public func url(for descriptor: ASRModelDescriptor) throws -> URL {
        let url = modelsDirectory.appendingPathComponent(descriptor.relativePath)
        guard fileManager.fileExists(atPath: url.path), fileManager.isReadableFile(atPath: url.path) else {
            throw MacSpeechTranslatorError.modelMissing
        }
        return url
    }

    public func delete(modelID: UUID) throws {
        guard let index = descriptors.firstIndex(where: { $0.id == modelID }) else { return }
        let descriptor = descriptors[index]
        let url = modelsDirectory.appendingPathComponent(descriptor.relativePath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        descriptors.remove(at: index)
        try persistDescriptors()
        if preferences.string(forKey: selectedModelKey) == modelID.uuidString {
            select(modelID: nil)
        }
    }

    private static func readDescriptors(from directory: URL, fileManager: FileManager) throws -> [ASRModelDescriptor] {
        let indexURL = directory.appendingPathComponent("models.json")
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([ASRModelDescriptor].self, from: Data(contentsOf: indexURL))
        } catch {
            throw MacSpeechTranslatorError.storageFailed("The ASR model index could not be read.")
        }
    }

    private func persistDescriptors() throws {
        let data = try JSONEncoder().encode(descriptors)
        try data.write(to: modelsDirectory.appendingPathComponent("models.json"), options: .atomic)
    }
}
