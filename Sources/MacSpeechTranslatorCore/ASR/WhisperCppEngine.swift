import Foundation
import OSLog

public struct WhisperCppConfiguration: Sendable, Equatable {
    /// URL of a locally built `whisper-cli` binary. It is nil until the user
    /// configures one; no cloud or mock fallback is used in this engine.
    public var executableURL: URL?

    public init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }
}

/// A local whisper.cpp adapter backed by the upstream `whisper-cli` binary.
/// It is a functional offline integration once both the CLI and GGUF model are
/// installed. The command-line boundary keeps this Swift package buildable
/// without shipping opaque prebuilt native objects; Scripts/bootstrap.sh pins
/// the upstream source used to build the binary.
public actor WhisperCppEngine: ASREngine {
    private let fileManager: FileManager
    private var runtimeConfiguration: WhisperCppConfiguration
    private var asrConfiguration = ASRConfiguration()
    private var modelURL: URL?
    private var currentExecution: LocalProcessExecution?
    private var loadedState: ASRModelState = .unloaded

    public init(configuration: WhisperCppConfiguration = WhisperCppConfiguration(), fileManager: FileManager = .default) {
        self.runtimeConfiguration = configuration
        self.fileManager = fileManager
    }

    public func setExecutableURL(_ url: URL?) {
        runtimeConfiguration.executableURL = url
        if url == nil { loadedState = .unloaded }
    }

    public func modelState() -> ASRModelState { loadedState }

    public func loadModel(at url: URL, configuration: ASRConfiguration) async throws {
        guard fileManager.fileExists(atPath: url.path), fileManager.isReadableFile(atPath: url.path) else {
            loadedState = .failed("Model file is missing or unreadable.")
            throw MacSpeechTranslatorError.modelMissing
        }
        guard let executableURL = runtimeConfiguration.executableURL,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            let message = "whisper.cpp CLI is not configured. Build the pinned local CLI and select it in Settings."
            loadedState = .unavailable(message)
            throw MacSpeechTranslatorError.asrUnavailable(message)
        }
        loadedState = .loading
        modelURL = url
        asrConfiguration = configuration
        loadedState = .loaded(name: url.lastPathComponent)
        DiagnosticsLogger.asr.notice("A local ASR model was configured.")
    }

    public func transcribePartial(audio: [Float], sampleRate: Int, context: ASRContext) async throws -> ASRResult {
        try await transcribe(audio: audio, sampleRate: sampleRate, context: context, final: false)
    }

    public func transcribeFinal(audio: [Float], sampleRate: Int, context: ASRContext) async throws -> ASRResult {
        try await transcribe(audio: audio, sampleRate: sampleRate, context: context, final: true)
    }

    public func cancelCurrentInference() async {
        currentExecution?.terminate()
        currentExecution = nil
        DiagnosticsLogger.asr.notice("Local ASR cancellation requested.")
    }

    public func unloadModel() async {
        await cancelCurrentInference()
        modelURL = nil
        loadedState = .unloaded
    }

    private func transcribe(audio: [Float], sampleRate: Int, context: ASRContext, final: Bool) async throws -> ASRResult {
        guard !audio.isEmpty else { return ASRResult(text: "") }
        guard let modelURL else { throw MacSpeechTranslatorError.modelMissing }
        guard let executableURL = runtimeConfiguration.executableURL,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw MacSpeechTranslatorError.asrUnavailable("whisper.cpp CLI is not configured.")
        }

        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("MacSpeechTranslator-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let inputURL = workDirectory.appendingPathComponent("input.wav")
        let outputBaseURL = workDirectory.appendingPathComponent("transcript")
        try WAVWriter.write(samples: audio, sampleRate: sampleRate, to: inputURL)

        var arguments = [
            "-m", modelURL.path,
            "-f", inputURL.path,
            "-l", asrConfiguration.languageCode,
            "-otxt",
            "-of", outputBaseURL.path,
            "-nt"
        ]
        let prompt = [asrConfiguration.initialPrompt, context.prompt]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")
        if !prompt.isEmpty { arguments += ["-p", prompt] }
        if !final { arguments += ["-t", "2"] }

        let execution = LocalProcessExecution(executableURL: executableURL, arguments: arguments)
        currentExecution = execution
        let startedAt = ProcessInfo.processInfo.systemUptime
        let output: Data
        do {
            output = try await execution.run()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MacSpeechTranslatorError.asrUnavailable(error.localizedDescription)
        }
        currentExecution = nil

        let transcriptURL = outputBaseURL.appendingPathExtension("txt")
        let rawText: String
        if fileManager.fileExists(atPath: transcriptURL.path) {
            rawText = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        } else {
            rawText = String(data: output, encoding: .utf8) ?? ""
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        return ASRResult(text: Self.cleanCLIOutput(rawText), processingTime: elapsed)
    }

    private static func cleanCLIOutput(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("whisper_") && !$0.hasPrefix("system_info:") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LocalProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let lock = NSLock()
    private var started = false
    private var cancellationRequested = false

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) { [self] in
                try start()
                // Drain as the process runs. Waiting first can deadlock when
                // a CLI fills its stdout/stderr pipe before exiting.
                let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationReason == .exit, process.terminationStatus == 0 {
                    return output
                }
                if Task.isCancelled || cancellationWasRequested() { throw CancellationError() }
                let message = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = "whisper.cpp exited with status \(process.terminationStatus)."
                throw MacSpeechTranslatorError.asrUnavailable(message?.isEmpty == false ? (message ?? fallback) : fallback)
            }.value
        }, onCancel: { [self] in
            terminate()
        })
    }

    func terminate() {
        lock.withLock {
            cancellationRequested = true
            if process.isRunning { process.terminate() }
        }
    }

    private func cancellationWasRequested() -> Bool {
        lock.withLock { cancellationRequested }
    }

    private func start() throws {
        try lock.withLock {
            guard !started else { return }
            try process.run()
            started = true
        }
    }
}
