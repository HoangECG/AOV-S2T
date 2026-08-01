import Darwin
import Foundation
import MacSpeechTranslatorCore

@main
struct MacSpeechTranslatorCoreChecks {
    static func main() async {
        let checks: [(String, () async throws -> Void)] = [
            ("ring buffer wraparound and reset", checkRingBuffer),
            ("channel mixing and resampling", checkAudioProcessing),
            ("WAV PCM16 header", checkWAVWriter),
            ("energy VAD state transition", checkEnergyVAD),
            ("endpoint stable silence", checkEndpoint),
            ("transcript stabilizer revision", checkStabilizer),
            ("model manager import", checkModelManager),
            ("local glossary persistence", checkGlossaryPersistence),
            ("local CLI adapter drains process output", checkWhisperCLIAdapter),
            ("local CLI adapter cancellation", checkWhisperCLICancellation),
            ("Vietnamese normalizer", checkNormalizer),
            ("Vietnamese sentence segmentation", checkSentenceSegmentation),
            ("controlled glossary correction", checkGlossary),
            ("final-only translation cache", checkTranslation),
            ("SQLite persistence", checkStorage),
            ("TXT JSON SRT VTT export", checkExporters),
            ("dataset WAV and manifest export", checkDatasetExport),
            ("realtime coordinator single final inference", checkRealtimeCoordinator),
            ("realtime coordinator finalizes valid speech with a capture timestamp", checkNoPartialFinal),
            ("realtime coordinator queues newest final", checkQueuedFinal),
            ("subtitle display delay planning", checkSubtitleDisplayDelay),
            ("loopback subtitle overlay server", checkSubtitleOverlayServer)
        ]
        var failures: [String] = []
        for (name, check) in checks {
            do {
                try await check()
                print("PASS \(name)")
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
                print("FAIL \(name): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            print("All \(checks.count) core checks passed.")
        } else {
            fputs("\(failures.count) core checks failed.\n", stderr)
            exit(1)
        }
    }

    private static func checkRingBuffer() async throws {
        let buffer = AudioRingBuffer(capacity: 4)
        try expectEqual(buffer.write([1, 2, 3]), 3)
        try expectEqual(buffer.read(maximumSamples: 2), [1, 2])
        _ = buffer.write([4, 5, 6, 7])
        try expectEqual(buffer.read(maximumSamples: 10), [4, 5, 6, 7])
        _ = buffer.write([1, 2, 3, 4, 5])
        try expect(buffer.overrunCount > 0, "expected overrun")
        buffer.reset()
        try expectEqual(buffer.availableSamples, 0)
    }

    private static func checkAudioProcessing() async throws {
        let mixed = AudioChannelMixer.mixToMono([1, -1, 0.5, 0.25], channelCount: 2, selection: .downmix)
        try expectEqual(mixed, [0, 0.375])
        let resampled = try LinearAudioResampler().resample(Array(repeating: 0.25, count: 48_000), from: 48_000, to: 16_000)
        try expect(abs(resampled.count - 16_000) <= 1, "unexpected output length")
        try expect(abs(resampled[0] - 0.25) < 0.0001, "unexpected resampled value")
        let converted = try AVAudioConverterResampler().resample(Array(repeating: 0.25, count: 960), from: 48_000, to: 16_000)
        try expect(abs(converted.count - 320) <= 8, "unexpected Core Audio converter length: \(converted.count)")
        let preferred = try PreferredAudioResampler().resample(Array(repeating: 0.25, count: 4_800), from: 48_000, to: 16_000)
        try expect(abs(preferred.count - 1_600) <= 1, "unexpected preferred resampler length")
    }

    private static func checkWAVWriter() async throws {
        let data = try WAVWriter.data(samples: [0, 0.5, -0.5], sampleRate: 16_000)
        try expectEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        try expectEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        try expectEqual(data.count, 50)
    }

    private static func checkEnergyVAD() async throws {
        let vad = EnergyVADFallback(configuration: VADConfiguration(
            speechThreshold: 0.01,
            releaseThreshold: 0.005,
            minimumSpeechDuration: 0.01,
            minimumSilenceDuration: 0.04,
            maximumUtteranceDuration: 10,
            adaptiveNoiseMultiplier: 1
        ))
        let frame: (Float, TimeInterval) -> AudioFrame = { level, time in
            AudioFrame(samples: Array(repeating: level, count: 320), sampleRate: 16_000, channelCount: 1, timestamp: time)
        }
        try expectEqual(try await vad.process(frame: frame(0.001, 0)).state, .silence)
        try expectEqual(try await vad.process(frame: frame(0.2, 0.02)).state, .possibleSpeech)
        try expectEqual(try await vad.process(frame: frame(0.2, 0.04)).state, .speech)
        try expectEqual(try await vad.process(frame: frame(0.001, 0.06)).state, .ending)
        try expectEqual(try await vad.process(frame: frame(0.001, 0.10)).state, .silence)
    }

    private static func checkEndpoint() async throws {
        let detector = EndpointDetector(configuration: EndpointConfiguration(punctuationSilence: 0.3, stableSilence: 0.5, maximumWait: 20, minimumSpeechDuration: 0.25))
        let partial = StabilizedTranscript(revision: 2, stablePrefix: "Xin chào", unstableSuffix: "")
        _ = await detector.evaluate(vad: VADResult(state: .speech, speechProbability: 1, isSpeech: true, timestamp: 1), partial: partial, utteranceStartedAt: 0)
        _ = await detector.evaluate(vad: VADResult(state: .ending, speechProbability: 0, isSpeech: false, timestamp: 1.1), partial: partial, utteranceStartedAt: 0)
        let final = await detector.evaluate(vad: VADResult(state: .silence, speechProbability: 0, isSpeech: false, timestamp: 1.7), partial: partial, utteranceStartedAt: 0)
        try expectEqual(final, .finalize(reason: "stable transcript and silence"))
    }

    private static func checkStabilizer() async throws {
        let stabilizer = RollingTranscriptStabilizer()
        let utterance = UUID()
        await stabilizer.reset(utteranceID: utterance)
        _ = await stabilizer.stabilize("hôm nay chúng ta", utteranceID: utterance)
        let second = await stabilizer.stabilize("hôm nay chúng ta sẽ triển", utteranceID: utterance)
        let third = await stabilizer.stabilize("hôm nay chúng ta sẽ triển khai", utteranceID: utterance)
        try expectEqual(second.stablePrefix, "hôm nay chúng ta")
        try expectEqual(third.displayText, "hôm nay chúng ta sẽ triển khai")
        try expectEqual(third.revision, 3)
    }

    private static func checkModelManager() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.gguf")
        try Data([1, 2, 3]).write(to: source)
        let manager = try ASRModelManager(applicationSupportDirectory: root)
        let descriptor = try await manager.importModel(from: source)
        let resolved = try await manager.url(for: descriptor)
        try expect(FileManager.default.fileExists(atPath: resolved.path), "model not copied")
        let selected = await manager.selectedModel()
        try expectEqual(selected?.id, descriptor.id)
    }

    private static func checkWhisperCLIAdapter() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.gguf")
        try Data([0]).write(to: model)
        let executable = root.appendingPathComponent("fake-whisper-cli")
        let script = """
        #!/bin/sh
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then
            output="$2"
            shift 2
          else
            shift
          fi
        done
        yes x | head -c 131072
        printf 'xin chao\\n' > "${output}.txt"
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let engine = WhisperCppEngine(configuration: WhisperCppConfiguration(executableURL: executable))
        try await engine.loadModel(at: model, configuration: ASRConfiguration())
        let result = try await engine.transcribeFinal(
            audio: Array(repeating: 0.1, count: 320),
            sampleRate: 16_000,
            context: ASRContext(sessionID: UUID(), utteranceID: UUID(), revision: 1)
        )
        try expectEqual(result.text, "xin chao")
    }

    private static func checkGlossaryPersistence() async throws {
        let key = "MacSpeechTranslatorCoreChecks.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let repository = GlossaryPreferencesRepository(key: key)
        let entry = GlossaryEntry(spokenForms: ["aov"], canonicalText: "AOV", targetTranslations: ["en": "Arena of Valor"])
        try await repository.save([entry])
        try expectEqual(try await repository.entries(), [entry])
    }

    private static func checkWhisperCLICancellation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.gguf")
        try Data([0]).write(to: model)
        let executable = root.appendingPathComponent("slow-whisper-cli")
        try "#!/bin/sh\nexec /bin/sleep 5\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let engine = WhisperCppEngine(configuration: WhisperCppConfiguration(executableURL: executable))
        try await engine.loadModel(at: model, configuration: ASRConfiguration())
        let task = Task {
            try await engine.transcribeFinal(
                audio: Array(repeating: 0.1, count: 320),
                sampleRate: 16_000,
                context: ASRContext(sessionID: UUID(), utteranceID: UUID(), revision: 1)
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        await engine.cancelCurrentInference()
        do {
            _ = try await task.value
            throw CheckFailure(message: "local CLI inference was not cancelled")
        } catch is CancellationError {
            // Expected: terminating the local process maps to cancellation.
        }
    }

    private static func checkNormalizer() async throws {
        let normalizer = VietnameseTextNormalizer()
        try expectEqual(normalizer.normalize("  hôm nay   chúng ta sẽ kiểm tra hệ thống  "), "Hôm nay chúng ta sẽ kiểm tra hệ thống.")
        try expectEqual(normalizer.normalize("doanh thu tăng 25 phần trăm"), "Doanh thu tăng 25%.")
    }

    private static func checkSentenceSegmentation() async throws {
        let text = "PGS.TS. An ở TP.HCM. Giá là 1.5 triệu. Xem https://example.com/a.b."
        let actual = VietnameseSentenceSegmenter().sentences(in: text)
        try expectEqual(actual, ["PGS.TS. An ở TP.HCM.", "Giá là 1.5 triệu.", "Xem https://example.com/a.b."])
    }

    private static func checkGlossary() async throws {
        let manager = GlossaryManager(entries: [GlossaryEntry(spokenForms: ["aov"], canonicalText: "AOV")])
        let corrected = await manager.applyCanonicalCorrections(to: "aov là trò chơi, xaov không đổi")
        try expectEqual(corrected, "AOV là trò chơi, xaov không đổi")
    }

    private static func checkTranslation() async throws {
        let engine = MockTranslationEngine(results: [TranslationResult(text: "Hello")])
        let coordinator = TranslationCoordinator(engine: engine)
        let sessionID = UUID()
        let partial = makeSegment(sessionID: sessionID, isFinal: false, text: "Xin chào")
        let partialResult = try await coordinator.translateFinal(segment: partial, source: .vietnamese, target: .english)
        try expect(partialResult == nil, "partial was translated")
        let one = makeSegment(sessionID: sessionID, isFinal: true, text: "Xin chào")
        let two = makeSegment(sessionID: sessionID, isFinal: true, text: "Xin chào")
        try expectEqual(try await coordinator.translateFinal(segment: one, source: .vietnamese, target: .english)?.text, "Hello")
        try expectEqual(try await coordinator.translateFinal(segment: two, source: .vietnamese, target: .english)?.text, "Hello")
        try expectEqual(await engine.requests.count, 1)
    }

    private static func checkStorage() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteTranscriptRepository(databaseURL: root.appendingPathComponent("test.sqlite"))
        let session = TranscriptionSession(title: "Test", audioSourceType: .microphone)
        try await repository.createSession(session)
        var item = makeSegment(sessionID: session.id, isFinal: true, text: "Xin chào.")
        try await repository.saveFinalSegment(item)
        var endedSession = session
        endedSession.endedAt = .now
        try await repository.createSession(endedSession)
        item.correctedText = "Xin chào bạn."
        try await repository.updateSegment(item)
        let sessions = try await repository.sessions(query: "tes")
        let segments = try await repository.segments(for: session.id)
        try expectEqual(sessions.count, 1)
        try expectEqual(segments.first?.correctedText, "Xin chào bạn.")
        try await repository.deleteSession(id: session.id)
        let remainingSessions = try await repository.sessions(query: nil)
        try expect(remainingSessions.isEmpty, "session not deleted")
    }

    private static func checkExporters() async throws {
        try expectEqual(TimestampFormatter.srt(3661.234), "01:01:01,234")
        try expectEqual(TimestampFormatter.vtt(-2), "00:00:00.000")
        let session = TranscriptionSession(audioSourceType: .microphone)
        var first = makeSegment(sessionID: session.id, isFinal: true, text: "Một.", start: 1, end: 2)
        first.translatedText = "One."
        let second = makeSegment(sessionID: session.id, isFinal: true, text: "Hai.", start: 1.5, end: 1.4)
        let srt = try String(decoding: SRTExporter().export(session: session, segments: [second, first], bilingual: false), as: UTF8.self)
        let vtt = try String(decoding: VTTExporter().export(session: session, segments: [first], bilingual: true), as: UTF8.self)
        let text = try String(decoding: TXTExporter().export(session: session, segments: [first], bilingual: true), as: UTF8.self)
        let json = try String(decoding: JSONExporter().export(session: session, segments: [first], bilingual: true), as: UTF8.self)
        try expect(srt.contains("00:00:01,000 --> 00:00:02,000"), "invalid first SRT cue")
        try expect(srt.contains("00:00:02,000 --> 00:00:02,001"), "invalid clamped SRT cue")
        try expect(vtt.hasPrefix("WEBVTT"), "missing VTT header")
        try expectEqual(text, "Một.\nOne.")
        try expect(json.contains("normalizedText"), "JSON missing normalized text")
    }

    private static func checkDatasetExport() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = try FileAudioRecordingRepository(rootDirectory: root.appendingPathComponent("recordings", isDirectory: true))
        let session = TranscriptionSession(audioSourceType: .microphone)
        var item = makeSegment(sessionID: session.id, isFinal: true, text: "Xin chào.")
        item.qualityLabel = .approved
        item.audioFileRelativePath = try await recordings.saveUtterance(samples: Array(repeating: 0.1, count: 1_600), sampleRate: 16_000, utteranceID: item.utteranceID)
        var secondSentence = TranscriptSegment(
            sessionID: session.id,
            utteranceID: item.utteranceID,
            revision: 1,
            startTime: 1,
            endTime: 2,
            rawText: item.rawText,
            normalizedText: "Bạn khỏe.",
            audioFileRelativePath: item.audioFileRelativePath
        )
        secondSentence.qualityLabel = .approved
        let destination = root.appendingPathComponent("dataset", isDirectory: true)
        let exporter = DatasetExporter(audioRepository: recordings)
        try await exporter.exportApproved(session: session, segments: [item, secondSentence], destination: destination)
        try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.jsonl").path), "missing manifest")
        try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("audio/utterance_\(item.utteranceID.uuidString).wav").path), "missing WAV")
        let manifest = try String(contentsOf: destination.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
        try expectEqual(manifest.split(whereSeparator: \.isNewline).count, 1)
        try expect(manifest.contains("Xin chào. Bạn khỏe."), "sentences were not combined for one utterance")
        try await recordings.deleteUtterance(relativePath: item.audioFileRelativePath ?? "")
        do {
            _ = try await recordings.loadUtterance(relativePath: item.audioFileRelativePath ?? "")
            throw CheckFailure(message: "recording was not deleted")
        } catch is MacSpeechTranslatorError {
            // Expected: the deleted file can no longer be loaded.
        }
    }

    private static func checkRealtimeCoordinator() async throws {
        let engine = MockASREngine(
            partialResults: [ASRResult(text: "hôm nay.")],
            finalResults: [ASRResult(text: "hôm nay")]
        )
        let vad = EnergyVADFallback(configuration: VADConfiguration(
            speechThreshold: 0.01,
            releaseThreshold: 0.005,
            minimumSpeechDuration: 0.02,
            minimumSilenceDuration: 0.04,
            maximumUtteranceDuration: 2,
            adaptiveNoiseMultiplier: 1
        ))
        let coordinator = RealtimeASRCoordinator(
            asrEngine: engine,
            vad: vad,
            endpointDetector: EndpointDetector(configuration: EndpointConfiguration(punctuationSilence: 0.02, stableSilence: 0.04, maximumWait: 2, minimumSpeechDuration: 0.01)),
            configuration: RealtimeConfiguration(partialInterval: 0.02, rollingWindow: 1, preRoll: 0.02, finalSilence: 0.04, maximumUtteranceDuration: 2, minimumValidSpeech: 0.01)
        )
        await coordinator.start(sessionID: UUID())
        let frame: (Float, TimeInterval) -> AudioFrame = { level, time in
            AudioFrame(samples: Array(repeating: level, count: 320), sampleRate: 16_000, channelCount: 1, timestamp: time)
        }
        for time in [0.0, 0.03, 0.08] { await coordinator.ingest(frame(0.2, time)) }
        try await Task.sleep(for: .milliseconds(30))
        for time in [0.12, 0.17, 0.24] { await coordinator.ingest(frame(0.001, time)) }
        try await Task.sleep(for: .milliseconds(80))
        try expectEqual(await engine.finalInvocationCount, 1)
        try expectEqual(await engine.maximumConcurrentInference, 1)
    }

    private static func checkQueuedFinal() async throws {
        let engine = MockASREngine(
            partialResults: [ASRResult(text: "câu đầu.")],
            finalResults: [ASRResult(text: "câu đầu"), ASRResult(text: "câu sau")],
            delay: 0.12
        )
        let vad = EnergyVADFallback(configuration: VADConfiguration(
            speechThreshold: 0.01,
            releaseThreshold: 0.005,
            minimumSpeechDuration: 0.02,
            minimumSilenceDuration: 0.04,
            maximumUtteranceDuration: 2,
            adaptiveNoiseMultiplier: 1
        ))
        let coordinator = RealtimeASRCoordinator(
            asrEngine: engine,
            vad: vad,
            endpointDetector: EndpointDetector(configuration: EndpointConfiguration(punctuationSilence: 0.02, stableSilence: 0.04, maximumWait: 2, minimumSpeechDuration: 0.01)),
            configuration: RealtimeConfiguration(partialInterval: 0.02, rollingWindow: 1, preRoll: 0.02, finalSilence: 0.04, maximumUtteranceDuration: 2, minimumValidSpeech: 0.01)
        )
        await coordinator.start(sessionID: UUID())
        let frame: (Float, TimeInterval) -> AudioFrame = { level, time in
            AudioFrame(samples: Array(repeating: level, count: 320), sampleRate: 16_000, channelCount: 1, timestamp: time)
        }

        for time in [0.0, 0.03, 0.08] { await coordinator.ingest(frame(0.2, time)) }
        try await Task.sleep(for: .milliseconds(160))
        for time in [0.12, 0.17, 0.24] { await coordinator.ingest(frame(0.001, time)) }
        for time in [0.30, 0.33, 0.38] { await coordinator.ingest(frame(0.2, time)) }
        for time in [0.42, 0.47, 0.54] { await coordinator.ingest(frame(0.001, time)) }
        for time in [0.60, 0.63, 0.68] { await coordinator.ingest(frame(0.2, time)) }
        for time in [0.72, 0.77, 0.84] { await coordinator.ingest(frame(0.001, time)) }
        try await Task.sleep(for: .milliseconds(450))

        try expectEqual(await engine.finalInvocationCount, 2)
        try expectEqual(await engine.maximumConcurrentInference, 1)
        try expectEqual(await coordinator.currentMetrics().droppedUtteranceCount, 1)
    }

    private static func checkNoPartialFinal() async throws {
        let engine = MockASREngine(finalResults: [ASRResult(text: "câu ngắn")])
        let vad = EnergyVADFallback(configuration: VADConfiguration(
            speechThreshold: 0.01,
            releaseThreshold: 0.005,
            minimumSpeechDuration: 0.02,
            minimumSilenceDuration: 0.04,
            maximumUtteranceDuration: 2,
            adaptiveNoiseMultiplier: 1
        ))
        let coordinator = RealtimeASRCoordinator(
            asrEngine: engine,
            vad: vad,
            endpointDetector: EndpointDetector(configuration: EndpointConfiguration(punctuationSilence: 0.02, stableSilence: 0.04, maximumWait: 2, minimumSpeechDuration: 0.01)),
            configuration: RealtimeConfiguration(partialInterval: 10, rollingWindow: 1, preRoll: 0.02, finalSilence: 0.04, maximumUtteranceDuration: 2, minimumValidSpeech: 0.04)
        )
        await coordinator.start(sessionID: UUID())
        let frame: (Float, TimeInterval) -> AudioFrame = { level, time in
            AudioFrame(
                samples: Array(repeating: level, count: 320),
                sampleRate: 16_000,
                channelCount: 1,
                timestamp: time,
                captureEndUptime: 10_000 + time
            )
        }
        for time in [0.0, 0.03, 0.08] { await coordinator.ingest(frame(0.2, time)) }
        for time in [0.12, 0.17, 0.24] { await coordinator.ingest(frame(0.001, time)) }
        try await Task.sleep(for: .milliseconds(80))
        try expectEqual(await engine.finalInvocationCount, 1)
        var eventIterator = coordinator.eventStream.makeAsyncIterator()
        let finalEvent = await eventIterator.next()
        try expectEqual(finalEvent?.type, .final)
        try expect((finalEvent?.captureEndUptime ?? 0) >= 10_000, "final event lost its capture timestamp")
    }

    private static func checkSubtitleDisplayDelay() async throws {
        try expectEqual(
            SubtitleDisplayDelay.remainingDelay(captureEndUptime: 100, displayDelay: 15, now: 105),
            10
        )
        try expectEqual(
            SubtitleDisplayDelay.remainingDelay(captureEndUptime: 100, displayDelay: 15, now: 120),
            0
        )
        try expectEqual(
            SubtitleDisplayDelay.remainingDelay(captureEndUptime: nil, displayDelay: 15, now: 100),
            0
        )
        try expectEqual(
            SubtitleDisplayDelay.remainingDelay(captureEndUptime: 100, displayDelay: -2, now: 100),
            0
        )
    }

    private static func checkSubtitleOverlayServer() async throws {
        let server = LocalSubtitleOverlayServer()
        defer { server.stop() }

        let overlayURL = try await server.start()
        try expectEqual(overlayURL.host, "127.0.0.1")
        try expect((overlayURL.port ?? 0) > 0, "overlay listener did not receive an ephemeral port")

        let subtitle = SubtitleOverlayPayload(
            sequence: 1,
            sourceText: "<script>not markup</script>",
            translatedText: "Hello"
        )
        server.publish(subtitle)

        let (overlayData, overlayResponse) = try await URLSession.shared.data(from: overlayURL)
        let html = String(decoding: overlayData, as: UTF8.self)
        let overlayHTTP = try httpResponse(overlayResponse)
        try expectEqual(overlayHTTP.statusCode, 200)
        try expectEqual(overlayHTTP.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        try expect(html.contains("background: transparent"), "overlay page is not transparent")
        try expect(html.contains("textContent"), "overlay page does not render text safely")

        var components = URLComponents(url: overlayURL, resolvingAgainstBaseURL: false)
        components?.path = "/subtitle"
        guard let subtitleURL = components?.url else {
            throw CheckFailure(message: "could not create subtitle endpoint URL")
        }
        let (subtitleData, subtitleResponse) = try await URLSession.shared.data(from: subtitleURL)
        let subtitleHTTP = try httpResponse(subtitleResponse)
        try expectEqual(subtitleHTTP.statusCode, 200)
        let snapshot = try JSONDecoder().decode(SubtitleOverlaySnapshot.self, from: subtitleData)
        try expectEqual(snapshot.subtitle, subtitle)

        server.clear(ifCurrentSequence: 0)
        let (unchangedData, _) = try await URLSession.shared.data(from: subtitleURL)
        try expectEqual(try JSONDecoder().decode(SubtitleOverlaySnapshot.self, from: unchangedData).subtitle, subtitle)

        server.clear(ifCurrentSequence: subtitle.sequence)
        let (clearedData, _) = try await URLSession.shared.data(from: subtitleURL)
        try expectEqual(try JSONDecoder().decode(SubtitleOverlaySnapshot.self, from: clearedData).subtitle, nil)

        var postRequest = URLRequest(url: subtitleURL)
        postRequest.httpMethod = "POST"
        let (_, postResponse) = try await URLSession.shared.data(for: postRequest)
        try expectEqual(try httpResponse(postResponse).statusCode, 405)
    }

    private static func makeSegment(
        sessionID: UUID,
        isFinal: Bool,
        text: String,
        start: TimeInterval = 0,
        end: TimeInterval = 1
    ) -> TranscriptSegment {
        TranscriptSegment(
            sessionID: sessionID,
            utteranceID: UUID(),
            revision: 1,
            startTime: start,
            endTime: end,
            rawText: text,
            normalizedText: text,
            isFinal: isFinal
        )
    }

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else {
        throw CheckFailure(message: "expected an HTTP response")
    }
    return response
}

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(message: message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual == expected else {
        throw CheckFailure(message: "Expected \(String(describing: expected)), got \(String(describing: actual)) at \(file):\(line)")
    }
}
