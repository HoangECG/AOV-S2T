import Foundation

/// Owns one near-realtime ASR pipeline. Audio frames are already expected to
/// be 16 kHz mono. It permits at most one inference at a time and replaces a
/// partial revision instead of appending it to the transcript.
public actor RealtimeASRCoordinator {
    public nonisolated let eventStream: AsyncStream<TranscriptEvent>
    public nonisolated let utteranceAudioStream: AsyncStream<FinalUtteranceAudio>

    private let eventContinuation: AsyncStream<TranscriptEvent>.Continuation
    private let utteranceAudioContinuation: AsyncStream<FinalUtteranceAudio>.Continuation
    private let asrEngine: any ASREngine
    private let vad: any VoiceActivityDetecting
    private let stabilizer: any TranscriptStabilizing
    private let endpointDetector: EndpointDetector
    private let preRoll: PreRollAudioBuffer
    private let normalizer: any TextNormalizing
    private let glossary: GlossaryManager?
    private let configuration: RealtimeConfiguration

    private var sessionID: UUID?
    private var activeUtterance: ActiveUtterance?
    private var partialTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var pendingFinal: FinalRequest?
    private var lastVADState: VADState = .silence
    private var candidateSpeechStartedAt: TimeInterval?
    private var metrics = ASRMetrics()

    public init(
        asrEngine: any ASREngine,
        vad: any VoiceActivityDetecting,
        stabilizer: any TranscriptStabilizing = RollingTranscriptStabilizer(),
        endpointDetector: EndpointDetector = EndpointDetector(),
        preRoll: PreRollAudioBuffer = PreRollAudioBuffer(),
        normalizer: any TextNormalizing = VietnameseTextNormalizer(),
        glossary: GlossaryManager? = nil,
        configuration: RealtimeConfiguration = RealtimeConfiguration()
    ) {
        self.asrEngine = asrEngine
        self.vad = vad
        self.stabilizer = stabilizer
        self.endpointDetector = endpointDetector
        self.preRoll = preRoll
        self.normalizer = normalizer
        self.glossary = glossary
        self.configuration = configuration
        // Transcript events are small, but bounded buffering still prevents a
        // stalled UI/persistence consumer from retaining an unbounded session.
        let pair = AsyncStream<TranscriptEvent>.makeStream(bufferingPolicy: .bufferingOldest(256))
        eventStream = pair.stream
        eventContinuation = pair.continuation
        let audioPair = AsyncStream<FinalUtteranceAudio>.makeStream(bufferingPolicy: .bufferingOldest(16))
        utteranceAudioStream = audioPair.stream
        utteranceAudioContinuation = audioPair.continuation
    }

    public func start(sessionID: UUID) async {
        await stop()
        self.sessionID = sessionID
        metrics = ASRMetrics()
        candidateSpeechStartedAt = nil
        await vad.reset()
        await endpointDetector.reset()
        await preRoll.reset()
    }

    public func stop() async {
        partialTask?.cancel()
        finalTask?.cancel()
        partialTask = nil
        finalTask = nil
        pendingFinal = nil
        activeUtterance = nil
        candidateSpeechStartedAt = nil
        await asrEngine.cancelCurrentInference()
        await endpointDetector.reset()
    }

    public func currentVADState() -> VADState { lastVADState }
    public func currentMetrics() -> ASRMetrics { metrics }

    public func ingest(_ frame: AudioFrame) async {
        guard frame.sampleRate == 16_000, frame.channelCount == 1 else {
            emitError("Realtime ASR expects 16 kHz mono audio.", utteranceID: activeUtterance?.id ?? UUID(), time: frame.timestamp)
            return
        }

        await preRoll.append(frame)
        let vadResult: VADResult
        do {
            vadResult = try await vad.process(frame: frame)
        } catch {
            DiagnosticsLogger.vad.error("VAD processing failed.")
            emitError("VAD failed: \(error.localizedDescription)", utteranceID: activeUtterance?.id ?? UUID(), time: frame.timestamp)
            return
        }
        lastVADState = vadResult.state

        guard let sessionID else { return }
        if activeUtterance == nil {
            if vadResult.isSpeech {
                candidateSpeechStartedAt = candidateSpeechStartedAt ?? frame.timestamp
            } else {
                candidateSpeechStartedAt = nil
            }
            guard vadResult.state == .speech else { return }
            let preRollSamples = await preRoll.snapshot()
            let startTime = max(0, frame.timestamp - Double(preRollSamples.count) / 16_000)
            let speechStartedAt = candidateSpeechStartedAt ?? frame.timestamp
            let utterance = ActiveUtterance(
                id: UUID(),
                startTime: startTime,
                endTime: frame.timestamp + frame.duration,
                endCaptureUptime: frame.captureEndUptime,
                samples: preRollSamples,
                speechDuration: max(frame.duration, frame.timestamp + frame.duration - speechStartedAt),
                partialRevision: 0,
                lastPartial: nil,
                lastPartialAt: frame.timestamp
            )
            activeUtterance = utterance
            candidateSpeechStartedAt = nil
            await stabilizer.reset(utteranceID: utterance.id)
            await endpointDetector.reset()
            return
        }

        guard var utterance = activeUtterance else { return }
        utterance.samples.append(contentsOf: frame.samples)
        utterance.endTime = frame.timestamp + frame.duration
        utterance.endCaptureUptime = frame.captureEndUptime
        if vadResult.isSpeech { utterance.speechDuration += frame.duration }
        activeUtterance = utterance

        if frame.timestamp - utterance.lastPartialAt >= configuration.partialInterval,
           partialTask == nil,
           finalTask == nil {
            schedulePartial(for: utterance, sessionID: sessionID)
        }

        let decision = await endpointDetector.evaluate(
            vad: vadResult,
            partial: utterance.lastPartial,
            utteranceStartedAt: utterance.startTime
        )
        switch decision {
        case .keepListening:
            break
        case .discardShortUtterance:
            // An empty partial is not proof that a valid utterance is empty:
            // the default partial interval is longer than short speech, and a
            // pending final deliberately suppresses partial inference. Run a
            // final pass whenever measured speech met the configured minimum.
            if utterance.speechDuration >= configuration.minimumValidSpeech {
                scheduleFinal(for: utterance, sessionID: sessionID)
            } else {
                activeUtterance = nil
                await preRoll.reset()
            }
        case .finalize:
            scheduleFinal(for: utterance, sessionID: sessionID)
        }
    }

    private func schedulePartial(for utterance: ActiveUtterance, sessionID: UUID) {
        guard partialTask == nil else { return }
        let engine = asrEngine
        let audio = Array(utterance.samples.suffix(Int(configuration.rollingWindow * 16_000)))
        let context = ASRContext(
            sessionID: sessionID,
            utteranceID: utterance.id,
            revision: utterance.partialRevision + 1
        )
        partialTask = Task { [weak self] in
            do {
                let result = try await engine.transcribePartial(audio: audio, sampleRate: 16_000, context: context)
                guard !Task.isCancelled else { return }
                await self?.acceptPartial(
                    result,
                    context: context,
                    endTime: utterance.endTime,
                    endCaptureUptime: utterance.endCaptureUptime
                )
            } catch is CancellationError {
                return
            } catch {
                await self?.partialFailed(error, context: context, time: utterance.endTime)
            }
        }
    }

    private func acceptPartial(
        _ result: ASRResult,
        context: ASRContext,
        endTime: TimeInterval,
        endCaptureUptime: TimeInterval?
    ) async {
        partialTask = nil
        guard var utterance = activeUtterance, utterance.id == context.utteranceID else { return }
        utterance.lastPartialAt = endTime
        let stabilized = await stabilizer.stabilize(result.text, utteranceID: context.utteranceID)
        utterance.partialRevision = stabilized.revision
        utterance.lastPartial = stabilized
        activeUtterance = utterance
        metrics.inputDuration = max(metrics.inputDuration, utterance.endTime - utterance.startTime)
        metrics.processingDuration += result.processingTime
        if let endCaptureUptime {
            metrics.partialLatency = max(0, ProcessInfo.processInfo.systemUptime - endCaptureUptime)
        }

        eventContinuation.yield(TranscriptEvent(
            sessionID: context.sessionID,
            utteranceID: context.utteranceID,
            revision: stabilized.revision,
            type: .partial,
            rawText: result.text,
            normalizedText: stabilized.displayText,
            startTime: utterance.startTime,
            endTime: endTime,
            isFinal: false,
            confidence: result.confidence,
            captureEndUptime: endCaptureUptime
        ))
    }

    private func partialFailed(_ error: Error, context: ASRContext, time: TimeInterval) async {
        partialTask = nil
        guard activeUtterance?.id == context.utteranceID else { return }
        DiagnosticsLogger.asr.error("Partial ASR failed.")
        emitError("Partial ASR failed: \(error.localizedDescription)", utteranceID: context.utteranceID, time: time)
    }

    private func scheduleFinal(for utterance: ActiveUtterance, sessionID: UUID) {
        activeUtterance = nil
        guard finalTask == nil else {
            // Keep at most the newest completed utterance while a final pass
            // is running. This bounds inference backlog; any replacement is
            // surfaced through an error event and metric instead of silent.
            if pendingFinal != nil {
                metrics.droppedUtteranceCount += 1
                emitError(
                    "ASR is saturated; an older queued utterance was dropped.",
                    utteranceID: utterance.id,
                    time: utterance.endTime
                )
            }
            pendingFinal = FinalRequest(utterance: utterance, sessionID: sessionID)
            return
        }
        beginFinal(for: utterance, sessionID: sessionID)
    }

    private func beginFinal(for utterance: ActiveUtterance, sessionID: UUID) {
        let priorPartial = partialTask
        partialTask = nil
        priorPartial?.cancel()
        let engine = asrEngine
        let context = ASRContext(
            sessionID: sessionID,
            utteranceID: utterance.id,
            revision: utterance.partialRevision + 1
        )
        finalTask = Task { [weak self] in
            await engine.cancelCurrentInference()
            if let priorPartial { await priorPartial.value }
            do {
                let result = try await engine.transcribeFinal(audio: utterance.samples, sampleRate: 16_000, context: context)
                guard !Task.isCancelled else { return }
                await self?.acceptFinal(result, context: context, utterance: utterance)
            } catch is CancellationError {
                return
            } catch {
                await self?.finalFailed(error, context: context, time: utterance.endTime)
            }
        }
    }

    private func acceptFinal(_ result: ASRResult, context: ASRContext, utterance: ActiveUtterance) async {
        finalTask = nil
        let glossaryCorrected: String
        if let glossary {
            glossaryCorrected = await glossary.applyCanonicalCorrections(to: result.text)
        } else {
            glossaryCorrected = result.text
        }
        let normalized = normalizer.normalize(glossaryCorrected)
        metrics.inputDuration += utterance.endTime - utterance.startTime
        metrics.processingDuration += result.processingTime
        if let endCaptureUptime = utterance.endCaptureUptime {
            metrics.finalLatency = max(0, ProcessInfo.processInfo.systemUptime - endCaptureUptime)
        }
        if normalized.isEmpty { metrics.emptyResultCount += 1 }

        if !normalized.isEmpty {
            utteranceAudioContinuation.yield(FinalUtteranceAudio(
                sessionID: context.sessionID,
                utteranceID: context.utteranceID,
                samples: utterance.samples
            ))
            eventContinuation.yield(TranscriptEvent(
                sessionID: context.sessionID,
                utteranceID: context.utteranceID,
                revision: context.revision,
                type: .final,
                rawText: result.text,
                normalizedText: normalized,
                startTime: utterance.startTime,
                endTime: utterance.endTime,
                isFinal: true,
                confidence: result.confidence,
                captureEndUptime: utterance.endCaptureUptime
            ))
        }
        startPendingFinalIfNeeded()
    }

    private func finalFailed(_ error: Error, context: ASRContext, time: TimeInterval) async {
        finalTask = nil
        DiagnosticsLogger.asr.error("Final ASR failed.")
        emitError("Final ASR failed: \(error.localizedDescription)", utteranceID: context.utteranceID, time: time)
        startPendingFinalIfNeeded()
    }

    private func startPendingFinalIfNeeded() {
        guard finalTask == nil, let pendingFinal else { return }
        self.pendingFinal = nil
        beginFinal(for: pendingFinal.utterance, sessionID: pendingFinal.sessionID)
    }

    private func emitError(_ message: String, utteranceID: UUID, time: TimeInterval) {
        guard let sessionID else { return }
        eventContinuation.yield(TranscriptEvent(
            sessionID: sessionID,
            utteranceID: utteranceID,
            revision: 0,
            type: .error,
            rawText: message,
            normalizedText: "",
            startTime: time,
            endTime: time,
            isFinal: false
        ))
    }
}

private struct ActiveUtterance: Sendable {
    let id: UUID
    let startTime: TimeInterval
    var endTime: TimeInterval
    var endCaptureUptime: TimeInterval?
    var samples: [Float]
    var speechDuration: TimeInterval
    var partialRevision: Int
    var lastPartial: StabilizedTranscript?
    var lastPartialAt: TimeInterval
}

private struct FinalRequest: Sendable {
    let utterance: ActiveUtterance
    let sessionID: UUID
}
