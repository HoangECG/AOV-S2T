import Foundation

/// Test-only dependency. AppDependencies never selects this engine for a real
/// capture session.
public actor MockASREngine: ASREngine {
    public var partialResults: [ASRResult]
    public var finalResults: [ASRResult]
    public private(set) var partialInvocationCount = 0
    public private(set) var finalInvocationCount = 0
    public private(set) var maximumConcurrentInference = 0
    public private(set) var wasCancelled = false
    public var delay: TimeInterval
    private var activeInferenceCount = 0

    public init(partialResults: [ASRResult] = [], finalResults: [ASRResult] = [], delay: TimeInterval = 0) {
        self.partialResults = partialResults
        self.finalResults = finalResults
        self.delay = delay
    }

    public func loadModel(at url: URL, configuration: ASRConfiguration) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MacSpeechTranslatorError.modelMissing }
    }

    public func transcribePartial(audio: [Float], sampleRate: Int, context: ASRContext) async throws -> ASRResult {
        partialInvocationCount += 1
        beginInference()
        defer { endInference() }
        try await pauseIfNeeded()
        return partialResults.isEmpty ? ASRResult(text: "") : partialResults.removeFirst()
    }

    public func transcribeFinal(audio: [Float], sampleRate: Int, context: ASRContext) async throws -> ASRResult {
        finalInvocationCount += 1
        beginInference()
        defer { endInference() }
        try await pauseIfNeeded()
        return finalResults.isEmpty ? ASRResult(text: "") : finalResults.removeFirst()
    }

    public func cancelCurrentInference() async { wasCancelled = true }
    public func unloadModel() async {}

    private func pauseIfNeeded() async throws {
        guard delay > 0 else { return }
        try await Task.sleep(for: .seconds(delay))
    }

    private func beginInference() {
        activeInferenceCount += 1
        maximumConcurrentInference = max(maximumConcurrentInference, activeInferenceCount)
    }

    private func endInference() {
        activeInferenceCount = max(0, activeInferenceCount - 1)
    }
}
