import AppKit
import Combine
import CoreGraphics
import Foundation
import MacSpeechTranslatorCore
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var audioSource: AudioSourceType = .microphone {
        didSet {
            refreshSourcesForSelection()
            persistAppSettings()
        }
    }
    @Published var devices: [AudioInputDevice] = []
    @Published var selectedDeviceID: String? { didSet { persistAppSettings() } }
    @Published var channelSelection: AudioChannelSelection = .downmix { didSet { persistAppSettings() } }
    @Published var systemAudioSources: [SystemAudioSource] = []
    @Published var selectedSystemAudioSourceID: String? { didSet { persistAppSettings() } }
    @Published var models: [ASRModelDescriptor] = []
    @Published var selectedModelID: UUID?
    @Published private(set) var whisperCLIURL: URL?
    @Published var targetLanguage: TranslationLanguage = .english { didSet { persistAppSettings() } }
    @Published var glossaryEntries: [GlossaryEntry] = []
    @Published var newGlossarySpokenForms = ""
    @Published var newGlossaryCanonicalText = ""
    @Published var newGlossaryTranslation = ""
    @Published var transcriptSegments: [TranscriptSegment] = []
    @Published var partialEvent: TranscriptEvent?
    @Published var history: [TranscriptionSession] = []
    @Published var historyQuery = ""
    @Published var selectedHistoryID: UUID?
    @Published var audioState: AudioInputState = .idle
    @Published var modelState: ASRModelState = .unloaded
    @Published var vadState: VADState = .silence
    @Published var audioMetrics = AudioMetrics()
    @Published var asrMetrics = ASRMetrics()
    @Published var translationStatus = "Idle"
    @Published var statusMessage = "Preparing local services…"
    @Published var isRunning = false
    @Published var recordAudio = false { didSet { persistAppSettings() } }
    @Published var saveDataset = false { didSet { persistAppSettings() } }
    @Published var exportFormat: TranscriptExportFormat = .text { didSet { persistAppSettings() } }
    @Published var bilingualExport = true { didSet { persistAppSettings() } }
    @Published var showSettings = false
    @Published var realtimeConfiguration = RealtimeConfiguration() { didSet { persistAppSettings() } }
    @Published var vadConfiguration = VADConfiguration() { didSet { persistAppSettings() } }
    /// Presentation-only holdback measured from the end of captured speech.
    /// It does not delay capture, ASR, persistence, translation, or export.
    @Published var subtitleDisplayDelay: TimeInterval = 0 {
        didSet {
            let sanitized = subtitleDisplayDelay.isFinite ? min(max(0, subtitleDisplayDelay), 60) : 0
            if sanitized != subtitleDisplayDelay {
                subtitleDisplayDelay = sanitized
                return
            }
            persistAppSettings()
        }
    }
    @Published private(set) var subtitleOverlayURL: URL?
    @Published private(set) var subtitleOverlayStatus = "Starting local overlay…"

    private let dependencies: AppDependencies
    private let glossary = GlossaryManager()
    private let sentenceFinalizer = DefaultSentenceFinalizer()
    private let processingPipeline = AudioProcessingPipeline()
    private let levelMeter = AudioLevelMeter()
    private var modelManager: ASRModelManager?
    private var transcriptRepository: (any TranscriptRepository)?
    private var audioRepository: (any AudioRecordingRepository)?
    private var glossaryRepository: (any GlossaryRepository)?
    private var whisperEngine: WhisperCppEngine?
    private var translationCoordinator: TranslationCoordinator?
    private var subtitleOverlayServer: LocalSubtitleOverlayServer?
    private var activeSource: (any AudioInputSource)?
    private var coordinator: RealtimeASRCoordinator?
    private var activeSession: TranscriptionSession?
    private var displayedSession: TranscriptionSession?
    private var frameTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var finalAudioTask: Task<Void, Never>?
    private var sourceStateTask: Task<Void, Never>?
    private var pendingAudioPaths: [UUID: String] = [:]
    private var lastMeterUpdate = 0.0
    private var isStoppingForSourceFailure = false
    private var subtitleOverlaySequence = 0
    private var subtitleOverlayGeneration = 0
    private var subtitlePublicationTasks: [UUID: Task<Void, Never>] = [:]

    var availableChannelSelections: [AudioChannelSelection] {
        let channels = devices.first(where: { $0.id == selectedDeviceID })?.channelCount ?? 1
        return [.downmix] + (0..<channels).map(AudioChannelSelection.channel)
    }

    var filteredHistory: [TranscriptionSession] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history }
        return history.filter { session in
            [
                session.title,
                session.notes,
                session.inputDeviceName ?? "",
                session.asrModelName ?? "",
                session.targetLanguage
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    init(dependencies: AppDependencies = .live) {
        self.dependencies = dependencies
        Task { await bootstrap() }
    }

    func bootstrap() async {
        do {
            restoreAppSettings()
            modelManager = try dependencies.makeModelManager()
            transcriptRepository = try dependencies.makeTranscriptRepository()
            audioRepository = try dependencies.makeAudioRepository()
            glossaryRepository = try dependencies.makeGlossaryRepository()
            whisperEngine = dependencies.makeWhisperEngine()
            if let whisperCLIURL {
                if FileManager.default.isExecutableFile(atPath: whisperCLIURL.path) {
                    await whisperEngine?.setExecutableURL(whisperCLIURL)
                } else {
                    self.whisperCLIURL = nil
                    persistAppSettings()
                }
            }
            translationCoordinator = TranslationCoordinator(engine: dependencies.makeTranslationEngine(), glossary: glossary)
            subtitleOverlayServer = dependencies.makeSubtitleOverlayServer()
            _ = await startSubtitleOverlayIfNeeded()
            let persistedGlossary = try await glossaryRepository?.entries() ?? []
            await glossary.replaceEntries(persistedGlossary)
            glossaryEntries = persistedGlossary
            statusMessage = "Offline services ready. Select a GGUF model and local whisper.cpp CLI."
            await refreshModels()
            await refreshAudioDevices()
            await refreshHistory()
        } catch {
            statusMessage = "Local storage setup failed: \(error.localizedDescription)"
        }
    }

    func openSubtitleOverlay() {
        Task {
            guard let url = await startSubtitleOverlayIfNeeded() else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func copySubtitleOverlayURL() {
        Task {
            guard let url = await startSubtitleOverlayIfNeeded() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            statusMessage = "Copied local subtitle overlay URL."
        }
    }

    func refreshSourcesForSelection() {
        Task {
            if audioSource == .microphone {
                await refreshAudioDevices()
            } else {
                await refreshSystemAudioSources()
            }
        }
    }

    func refreshAudioDevices() async {
        do {
            devices = try await dependencies.audioDeviceProvider.inputDevices()
            if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = devices.first(where: \.isDefault)?.id ?? devices.first?.id
            }
        } catch {
            statusMessage = "Could not enumerate input devices: \(error.localizedDescription)"
        }
    }

    func refreshSystemAudioSources() async {
        do {
            systemAudioSources = try await dependencies.systemAudioSourceProvider.systemAudioSources()
            if selectedSystemAudioSourceID == nil || !systemAudioSources.contains(where: { $0.id == selectedSystemAudioSourceID }) {
                selectedSystemAudioSourceID = systemAudioSources.first?.id
            }
        } catch {
            statusMessage = "System audio sources need Screen Recording permission: \(error.localizedDescription)"
        }
    }

    func refreshModels() async {
        guard let modelManager else { return }
        models = await modelManager.models()
        selectedModelID = await modelManager.selectedModel()?.id
    }

    func refreshHistory() async {
        guard let transcriptRepository else { return }
        do {
            history = try await transcriptRepository.sessions(query: nil)
        } catch {
            statusMessage = "Could not load local history: \(error.localizedDescription)"
        }
    }

    func importModel() {
        let panel = NSOpenPanel()
        panel.title = "Import whisper.cpp model"
        panel.message = "Choose a local GGUF model. The app will copy it into Application Support."
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data, UTType(filenameExtension: "bin") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.importModel(from: url) }
        }
    }

    private func importModel(from url: URL) async {
        guard let modelManager else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let descriptor = try await modelManager.importModel(from: url)
            models = await modelManager.models()
            selectedModelID = descriptor.id
            statusMessage = "Imported \(descriptor.displayName)."
        } catch {
            statusMessage = "Model import failed: \(error.localizedDescription)"
        }
    }

    func chooseWhisperCLI() {
        let panel = NSOpenPanel()
        panel.title = "Choose local whisper.cpp CLI"
        panel.message = "Choose the executable built from the pinned whisper.cpp source."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.configureWhisperCLI(at: url) }
        }
    }

    private func configureWhisperCLI(at url: URL) async {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            statusMessage = "The selected whisper.cpp CLI is not executable."
            return
        }
        whisperCLIURL = url
        persistAppSettings()
        await whisperEngine?.setExecutableURL(url)
        await refreshModelState()
        statusMessage = "Configured local whisper.cpp CLI."
    }

    func selectModel(_ id: UUID?) {
        selectedModelID = id
        Task { await modelManager?.select(modelID: id) }
    }

    private func startSubtitleOverlayIfNeeded() async -> URL? {
        guard let subtitleOverlayServer else {
            subtitleOverlayStatus = "Overlay is unavailable while local services start."
            return nil
        }
        if let url = subtitleOverlayServer.url {
            subtitleOverlayURL = url
            return url
        }
        subtitleOverlayURL = nil
        subtitleOverlayStatus = "Starting local overlay…"
        do {
            let url = try await subtitleOverlayServer.start()
            subtitleOverlayURL = url
            subtitleOverlayStatus = "Ready on 127.0.0.1"
            return url
        } catch {
            subtitleOverlayStatus = "Unavailable: \(error.localizedDescription)"
            statusMessage = "Subtitle overlay unavailable: \(error.localizedDescription)"
            return nil
        }
    }

    private func clearSubtitleOverlay() {
        subtitleOverlayGeneration += 1
        for task in subtitlePublicationTasks.values {
            task.cancel()
        }
        subtitlePublicationTasks.removeAll()
        subtitleOverlayServer?.clear()
    }

    private func scheduleSubtitleOverlay(
        _ segment: TranscriptSegment,
        captureEndUptime: TimeInterval?,
        displayDelay: TimeInterval
    ) {
        guard let subtitleOverlayServer else { return }
        subtitleOverlaySequence += 1
        let subtitle = SubtitleOverlayPayload(
            sequence: subtitleOverlaySequence,
            sourceText: segment.preferredText,
            translatedText: segment.translatedText
        )
        let generation = subtitleOverlayGeneration
        let remainingDelay = SubtitleDisplayDelay.remainingDelay(
            captureEndUptime: captureEndUptime,
            displayDelay: displayDelay,
            now: ProcessInfo.processInfo.systemUptime
        )
        guard remainingDelay > 0 else {
            subtitleOverlayServer.publish(subtitle)
            return
        }
        let taskID = UUID()
        let task = Task { [weak self, subtitleOverlayServer] in
            if remainingDelay > 0 {
                let nanoseconds = UInt64((remainingDelay * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard !Task.isCancelled, let self, self.subtitleOverlayGeneration == generation else { return }
            subtitleOverlayServer.publish(subtitle)
            self.subtitlePublicationTasks[taskID] = nil
        }
        subtitlePublicationTasks[taskID] = task
    }

    func startCapture() {
        Task { await startCaptureImpl() }
    }

    private func startCaptureImpl() async {
        guard !isRunning else { return }
        guard let whisperEngine, let modelManager, let transcriptRepository else {
            statusMessage = "The app has not finished preparing local services."
            return
        }
        guard let selectedModelID, let descriptor = models.first(where: { $0.id == selectedModelID }) else {
            statusMessage = "Import and select a local GGUF model before starting."
            return
        }
        guard audioSource != .systemAudio || requestScreenRecordingPermissionIfNeeded() else {
            return
        }
        clearSubtitleOverlay()
        _ = await startSubtitleOverlayIfNeeded()
        let inputSource: any AudioInputSource = audioSource == .microphone ? DefaultMicrophoneAudioSource() : SystemAudioInputSource()
        let sourceConfiguration = AudioInputConfiguration(
            source: audioSource,
            deviceID: selectedDeviceID,
            channelSelection: channelSelection,
            systemAudioSourceID: selectedSystemAudioSourceID
        )

        do {
            let modelURL = try await modelManager.url(for: descriptor)
            let prompt = await glossary.hotwordPrompt()
            try await whisperEngine.loadModel(at: modelURL, configuration: ASRConfiguration(initialPrompt: prompt))
            modelState = await whisperEngine.modelState()
            try await inputSource.prepare(configuration: sourceConfiguration)

            let deviceName = devices.first(where: { $0.id == selectedDeviceID })?.name
            let session = TranscriptionSession(
                title: "Session \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                audioSourceType: audioSource,
                inputDeviceName: audioSource == .microphone ? deviceName : selectedSystemAudioSourceID,
                asrModelName: descriptor.displayName,
                targetLanguage: targetLanguage.rawValue,
                appVersion: AppConfiguration.appVersion
            )
            try await transcriptRepository.createSession(session)
            let realtimeCoordinator = RealtimeASRCoordinator(
                asrEngine: whisperEngine,
                vad: EnergyVADFallback(configuration: vadConfiguration),
                endpointDetector: EndpointDetector(configuration: EndpointConfiguration(
                    stableSilence: realtimeConfiguration.finalSilence,
                    maximumWait: realtimeConfiguration.maximumUtteranceDuration,
                    minimumSpeechDuration: realtimeConfiguration.minimumValidSpeech
                )),
                preRoll: PreRollAudioBuffer(maximumDuration: realtimeConfiguration.preRoll),
                glossary: glossary,
                configuration: realtimeConfiguration
            )
            await realtimeCoordinator.start(sessionID: session.id)
            activeSession = session
            displayedSession = session
            transcriptSegments = []
            partialEvent = nil
            pendingAudioPaths = [:]
            coordinator = realtimeCoordinator
            activeSource = inputSource
            attachStreams(source: inputSource, coordinator: realtimeCoordinator, channelSelection: channelSelection)
            try await inputSource.start()
            isRunning = true
            audioState = .recording
            statusMessage = "Capturing locally with Energy VAD fallback."
            await refreshHistory()
        } catch {
            modelState = await whisperEngine.modelState()
            statusMessage = "Could not start: \(error.localizedDescription)"
            await inputSource.stop()
        }
    }

    func stopCapture() {
        Task { await stopCaptureImpl() }
    }

    private func stopCaptureImpl() async {
        frameTask?.cancel()
        eventTask?.cancel()
        finalAudioTask?.cancel()
        sourceStateTask?.cancel()
        frameTask = nil
        eventTask = nil
        finalAudioTask = nil
        sourceStateTask = nil
        if let activeSource { await activeSource.stop() }
        if let coordinator { await coordinator.stop() }
        await translationCoordinator?.cancelAll()
        if var session = activeSession {
            session.endedAt = .now
            try? await transcriptRepository?.createSession(session)
            activeSession = session
        }
        activeSource = nil
        coordinator = nil
        isRunning = false
        audioState = .stopped
        partialEvent = nil
        clearSubtitleOverlay()
        statusMessage = "Stopped. Final-only transcript history remains on this Mac."
        await refreshHistory()
    }

    private func attachStreams(
        source: any AudioInputSource,
        coordinator: RealtimeASRCoordinator,
        channelSelection: AudioChannelSelection
    ) {
        // Keep conversion, VAD, and ASR coordination off MainActor. UI updates
        // are explicitly marshalled back through AppState methods below.
        frameTask = Task.detached(priority: .userInitiated) { [weak self, processingPipeline, levelMeter, source, coordinator] in
            do {
                for try await rawFrame in source.audioStream {
                    guard !Task.isCancelled else { return }
                    let processed = try processingPipeline.process(rawFrame, selection: channelSelection)
                    await levelMeter.process(processed)
                    await coordinator.ingest(processed)
                    await self?.updateLiveMetrics(coordinator: coordinator, levelMeter: levelMeter, source: source)
                }
            } catch {
                await self?.handleCaptureFailure(error)
            }
        }
        eventTask = Task { [weak self] in
            for await event in coordinator.eventStream {
                guard !Task.isCancelled else { return }
                await self?.receive(event)
            }
        }
        finalAudioTask = Task { [weak self] in
            for await audio in coordinator.utteranceAudioStream {
                guard !Task.isCancelled else { return }
                await self?.receiveFinalAudio(audio)
            }
        }
        sourceStateTask = Task { [weak self] in
            for await state in source.stateStream {
                guard !Task.isCancelled else { return }
                self?.receiveAudioState(state)
            }
        }
    }

    private func updateLiveMetrics(
        coordinator: RealtimeASRCoordinator,
        levelMeter: AudioLevelMeter,
        source: any AudioInputSource
    ) async {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMeterUpdate >= 0.1 else { return }
        lastMeterUpdate = now
        let captureMetrics = source.captureMetrics()
        audioMetrics = await levelMeter.snapshot(
            overruns: captureMetrics.ringBufferOverruns,
            droppedFrames: captureMetrics.droppedFrames
        )
        vadState = await coordinator.currentVADState()
        asrMetrics = await coordinator.currentMetrics()
    }

    private func receiveAudioState(_ state: AudioInputState) {
        audioState = state
        switch state {
        case .failed(let message), .unavailable(let message):
            statusMessage = message
            guard isRunning, !isStoppingForSourceFailure else { return }
            isStoppingForSourceFailure = true
            Task { [weak self] in
                guard let self else { return }
                await self.stopCaptureImpl()
                self.statusMessage = "Capture stopped safely: \(message)"
                self.isStoppingForSourceFailure = false
            }
        default:
            break
        }
    }

    private func handleCaptureFailure(_ error: Error) {
        let message = "Audio stream failed: \(error.localizedDescription)"
        statusMessage = message
        guard isRunning, !isStoppingForSourceFailure else { return }
        isStoppingForSourceFailure = true
        Task { [weak self] in
            guard let self else { return }
            await self.stopCaptureImpl()
            self.statusMessage = "Capture stopped safely: \(message)"
            self.isStoppingForSourceFailure = false
        }
    }

    private func receive(_ event: TranscriptEvent) async {
        switch event.type {
        case .partial:
            partialEvent = event
        case .error:
            statusMessage = event.rawText
        case .final:
            partialEvent = nil
            await persistFinal(event)
        }
    }

    private func persistFinal(_ event: TranscriptEvent) async {
        guard let transcriptRepository else { return }
        let sentences = await sentenceFinalizer.finalize(text: event.normalizedText, startTime: event.startTime, endTime: event.endTime)
        let displayDelay = subtitleDisplayDelay
        for sentence in sentences {
            var segment = TranscriptSegment(
                sessionID: event.sessionID,
                utteranceID: event.utteranceID,
                revision: event.revision,
                startTime: sentence.startTime,
                endTime: sentence.endTime,
                rawText: event.rawText,
                normalizedText: sentence.text,
                confidence: event.confidence,
                audioFileRelativePath: pendingAudioPaths[event.utteranceID]
            )
            do {
                try await transcriptRepository.saveFinalSegment(segment)
                transcriptSegments.append(segment)
                await translate(&segment)
                let sentenceCaptureEndUptime = event.captureEndUptime.map {
                    $0 - max(0, event.endTime - sentence.endTime)
                }
                scheduleSubtitleOverlay(
                    segment,
                    captureEndUptime: sentenceCaptureEndUptime,
                    displayDelay: displayDelay
                )
            } catch {
                statusMessage = "Could not save final transcript: \(error.localizedDescription)"
            }
        }
    }

    private func translate(_ segment: inout TranscriptSegment) async {
        guard let translationCoordinator else { return }
        translationStatus = "Translating final sentence…"
        do {
            if let result = try await translationCoordinator.translateFinal(
                segment: segment,
                source: .vietnamese,
                target: targetLanguage
            ) {
                segment.translatedText = result.text
                try await transcriptRepository?.updateSegment(segment)
                if let index = transcriptSegments.firstIndex(where: { $0.id == segment.id }) {
                    transcriptSegments[index] = segment
                }
            }
            translationStatus = "Idle"
        } catch {
            translationStatus = "Unavailable"
            statusMessage = "Translation skipped: \(error.localizedDescription)"
        }
    }

    private func receiveFinalAudio(_ audio: FinalUtteranceAudio) async {
        guard recordAudio, let audioRepository else { return }
        do {
            let relativePath = try await audioRepository.saveUtterance(
                samples: audio.samples,
                sampleRate: audio.sampleRate,
                utteranceID: audio.utteranceID
            )
            pendingAudioPaths[audio.utteranceID] = relativePath
            for index in transcriptSegments.indices where transcriptSegments[index].utteranceID == audio.utteranceID {
                transcriptSegments[index].audioFileRelativePath = relativePath
                try await transcriptRepository?.updateSegment(transcriptSegments[index])
            }
        } catch {
            statusMessage = "Audio recording failed: \(error.localizedDescription)"
        }
    }

    func editSegment(id: UUID, correctedText: String) {
        Task {
            guard let index = transcriptSegments.firstIndex(where: { $0.id == id }) else { return }
            transcriptSegments[index].correctedText = correctedText
            do {
                try await transcriptRepository?.updateSegment(transcriptSegments[index])
            } catch {
                statusMessage = "Could not save correction: \(error.localizedDescription)"
            }
        }
    }

    func setRecordAudio(_ enabled: Bool) {
        recordAudio = enabled
        if enabled {
            statusMessage = "Privacy notice: final utterance WAV files will be kept locally until you delete the session."
        }
    }

    func addGlossaryEntry() {
        let spokenForms = newGlossarySpokenForms
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let canonicalText = newGlossaryCanonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenForms.isEmpty, !canonicalText.isEmpty else {
            statusMessage = "Enter at least one spoken form and a canonical glossary term."
            return
        }
        let translation = newGlossaryTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        let translations = translation.isEmpty ? [:] : [targetLanguage.rawValue: translation]
        let entry = GlossaryEntry(
            spokenForms: spokenForms,
            canonicalText: canonicalText,
            targetTranslations: translations
        )
        Task {
            await glossary.upsert(entry)
            await saveGlossary()
            newGlossarySpokenForms = ""
            newGlossaryCanonicalText = ""
            newGlossaryTranslation = ""
        }
    }

    func removeGlossaryEntry(id: UUID) {
        Task {
            await glossary.remove(id: id)
            await saveGlossary()
        }
    }

    private func saveGlossary() async {
        guard let glossaryRepository else { return }
        do {
            let entries = await glossary.allEntries()
            try await glossaryRepository.save(entries)
            glossaryEntries = entries
        } catch {
            statusMessage = "Could not save the local glossary: \(error.localizedDescription)"
        }
    }

    func setQuality(id: UUID, quality: QualityLabel) {
        Task {
            guard let index = transcriptSegments.firstIndex(where: { $0.id == id }) else { return }
            transcriptSegments[index].qualityLabel = quality
            do {
                try await transcriptRepository?.updateSegment(transcriptSegments[index])
            } catch {
                statusMessage = "Could not save quality label: \(error.localizedDescription)"
            }
        }
    }

    func openHistory(_ session: TranscriptionSession) {
        guard !isRunning else {
            statusMessage = "Stop the active capture before opening another session."
            return
        }
        Task {
            do {
                transcriptSegments = try await transcriptRepository?.segments(for: session.id) ?? []
                displayedSession = session
                selectedHistoryID = session.id
                partialEvent = nil
                statusMessage = "Opened local session history."
            } catch {
                statusMessage = "Could not open session: \(error.localizedDescription)"
            }
        }
    }

    func deleteHistory(_ session: TranscriptionSession) {
        Task {
            do {
                let segments = try await transcriptRepository?.segments(for: session.id) ?? []
                let audioPaths = Set(segments.compactMap(\.audioFileRelativePath))
                for path in audioPaths {
                    try await audioRepository?.deleteUtterance(relativePath: path)
                }
                try await transcriptRepository?.deleteSession(id: session.id)
                if selectedHistoryID == session.id {
                    transcriptSegments = []
                    displayedSession = nil
                    selectedHistoryID = nil
                }
                await refreshHistory()
            } catch {
                statusMessage = "Could not delete session: \(error.localizedDescription)"
            }
        }
    }

    func exportCurrentSession() {
        guard let session = displayedSession ?? activeSession else {
            statusMessage = "There is no session to export."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacSpeechTranslator-\(session.id.uuidString).\(exportFormat.rawValue)"
        panel.allowedContentTypes = [contentType(for: exportFormat)]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.writeExport(session: session, to: url) }
        }
    }

    private func writeExport(session: TranscriptionSession, to url: URL) async {
        do {
            let exporter = TranscriptExporterFactory.make(format: exportFormat)
            let data = try exporter.export(session: session, segments: transcriptSegments, bilingual: bilingualExport)
            try data.write(to: url, options: .atomic)
            statusMessage = "Exported \(exportFormat.rawValue.uppercased()) locally."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func exportApprovedDataset() {
        guard saveDataset else {
            statusMessage = "Enable the dataset export workflow in Settings before exporting approved recordings."
            return
        }
        guard let session = displayedSession ?? activeSession, let audioRepository else {
            statusMessage = "No recorded session is available for dataset export."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose an empty dataset folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                guard let self else { return }
                do {
                    let exporter = DatasetExporter(audioRepository: audioRepository)
                    try await exporter.exportApproved(session: session, segments: self.transcriptSegments, destination: url)
                    self.statusMessage = "Exported approved audio and manifest."
                } catch {
                    self.statusMessage = "Dataset export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func requestScreenRecordingPermission() {
        if requestScreenRecordingPermissionIfNeeded() {
            statusMessage = "Screen Recording permission is already granted."
        }
    }

    private func requestScreenRecordingPermissionIfNeeded() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        _ = CGRequestScreenCaptureAccess()
        guard CGPreflightScreenCaptureAccess() else {
            statusMessage = "Allow MacSpeechTranslator in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen the app before starting."
            return false
        }
        return true
    }

    private func refreshModelState() async {
        if let whisperEngine { modelState = await whisperEngine.modelState() }
    }

    private func restoreAppSettings() {
        guard let data = UserDefaults.standard.data(forKey: PersistedAppSettings.key),
              let saved = try? JSONDecoder().decode(PersistedAppSettings.self, from: data) else {
            return
        }
        audioSource = saved.audioSource
        selectedDeviceID = saved.selectedDeviceID
        channelSelection = saved.channelSelection
        selectedSystemAudioSourceID = saved.selectedSystemAudioSourceID
        targetLanguage = saved.targetLanguage
        recordAudio = saved.recordAudio
        saveDataset = saved.saveDataset
        exportFormat = saved.exportFormat
        bilingualExport = saved.bilingualExport
        realtimeConfiguration = saved.realtimeConfiguration
        vadConfiguration = saved.vadConfiguration
        subtitleDisplayDelay = min(max(0, saved.subtitleDisplayDelay ?? 0), 60)
        whisperCLIURL = saved.whisperCLIPath.map { URL(fileURLWithPath: $0) }
        // Other restored properties persist from their observers. Write once
        // after restoring the CLI too, so those intermediate writes cannot
        // erase the optional CLI path from an older settings payload.
        persistAppSettings()
    }

    private func persistAppSettings() {
        let settings = PersistedAppSettings(
            audioSource: audioSource,
            selectedDeviceID: selectedDeviceID,
            channelSelection: channelSelection,
            selectedSystemAudioSourceID: selectedSystemAudioSourceID,
            targetLanguage: targetLanguage,
            recordAudio: recordAudio,
            saveDataset: saveDataset,
            exportFormat: exportFormat,
            bilingualExport: bilingualExport,
            realtimeConfiguration: realtimeConfiguration,
            vadConfiguration: vadConfiguration,
            subtitleDisplayDelay: subtitleDisplayDelay,
            whisperCLIPath: whisperCLIURL?.path
        )
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: PersistedAppSettings.key)
    }

    private func contentType(for format: TranscriptExportFormat) -> UTType {
        switch format {
        case .text: .plainText
        case .json: .json
        case .srt: UTType(filenameExtension: "srt") ?? .plainText
        case .vtt: UTType(filenameExtension: "vtt") ?? .plainText
        }
    }
}

private struct PersistedAppSettings: Codable {
    static let key = "MacSpeechTranslator.appSettings"

    var audioSource: AudioSourceType
    var selectedDeviceID: String?
    var channelSelection: AudioChannelSelection
    var selectedSystemAudioSourceID: String?
    var targetLanguage: TranslationLanguage
    var recordAudio: Bool
    var saveDataset: Bool
    var exportFormat: TranscriptExportFormat
    var bilingualExport: Bool
    var realtimeConfiguration: RealtimeConfiguration
    var vadConfiguration: VADConfiguration
    /// Optional so settings saved before the overlay existed still decode.
    var subtitleDisplayDelay: TimeInterval?
    /// Optional so settings saved before the configured CLI was persisted still decode.
    var whisperCLIPath: String?
}
