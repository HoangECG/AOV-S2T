import MacSpeechTranslatorCore
import SwiftUI

struct MainView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            historySidebar
        } detail: {
            VStack(spacing: 0) {
                controlBar
                Divider()
                statusPanel
                Divider()
                overlayWorkspace
            }
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView(appState: appState)
        }
    }

    private var historySidebar: some View {
        List(selection: $appState.selectedHistoryID) {
            Section("Sessions") {
                ForEach(appState.filteredHistory) { session in
                    Button {
                        appState.openHistory(session)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.title).lineLimit(1)
                            Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(historyMetadata(session))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(Optional(session.id))
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            appState.deleteHistory(session)
                        }
                        .disabled(appState.isRunning)
                    }
                }
            }
        }
        .navigationTitle("History")
        .searchable(text: $appState.historyQuery, prompt: "Search local sessions")
        .disabled(appState.isRunning)
        .toolbar {
            Button {
                Task { await appState.refreshHistory() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh local history")
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $appState.audioSource) {
                ForEach(AudioSourceType.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .frame(width: 190)
            .disabled(appState.isRunning)

            if appState.audioSource == .microphone {
                Picker("Input", selection: $appState.selectedDeviceID) {
                    Text("No input").tag(Optional<String>.none)
                    ForEach(appState.devices) { device in
                        Text("\(device.name) · \(Int(device.sampleRate)) Hz · \(device.channelCount) ch")
                            .tag(Optional(device.id))
                    }
                }
                .frame(minWidth: 250)
                .disabled(appState.isRunning)
                Picker("Channel", selection: $appState.channelSelection) {
                    ForEach(appState.availableChannelSelections, id: \.self) { selection in
                        Text(selection.displayName).tag(selection)
                    }
                }
                .frame(width: 145)
                .disabled(appState.isRunning)
            } else {
                Picker("System source", selection: $appState.selectedSystemAudioSourceID) {
                    Text("No source").tag(Optional<String>.none)
                    ForEach(appState.systemAudioSources) { source in
                        Text(source.displayName).tag(Optional(source.id))
                    }
                }
                .frame(minWidth: 250)
                .disabled(appState.isRunning)
            }

            Picker("Model", selection: $appState.selectedModelID) {
                Text("No model").tag(Optional<UUID>.none)
                ForEach(appState.models) { model in
                    Text(model.displayName).tag(Optional(model.id))
                }
            }
            .frame(minWidth: 150)
            .onChange(of: appState.selectedModelID) { _, id in appState.selectModel(id) }
            .disabled(appState.isRunning)

            Picker("Translate to", selection: $appState.targetLanguage) {
                ForEach(AppConfiguration.supportedTargetLanguages) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .frame(width: 140)
            .disabled(appState.isRunning)

            Spacer(minLength: 0)

            Toggle(isOn: Binding(
                get: { appState.recordAudio },
                set: { appState.setRecordAudio($0) }
            )) {
                Label("Record", systemImage: "record.circle")
            }
            .toggleStyle(.switch)
            .help("Save final utterance WAV files locally")
            .disabled(appState.isRunning)

            if appState.isRunning {
                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    appState.stopCapture()
                }
            } else {
                Button("Start", systemImage: "play.fill") {
                    appState.startCapture()
                }
                .buttonStyle(.borderedProminent)
            }

            Menu {
                Picker("Format", selection: $appState.exportFormat) {
                    ForEach(TranscriptExportFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                Toggle("Include translation", isOn: $appState.bilingualExport)
                Divider()
                Button("Export Session…") { appState.exportCurrentSession() }
                Button("Export Approved Dataset…") { appState.exportApprovedDataset() }
                    .disabled(!appState.saveDataset)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Button {
                appState.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
        .padding(12)
    }

    private var statusPanel: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Label(appState.audioState.displayName, systemImage: "waveform")
                Label(modelStateText, systemImage: "cpu")
                Label("VAD: \(appState.vadState.rawValue)", systemImage: "ear")
                Label("Translation: \(appState.translationStatus)", systemImage: "character.book.closed")
                Label("Overlay: \(appState.subtitleOverlayStatus)", systemImage: "rectangle.on.rectangle")
            }
            .font(.caption)
            .frame(width: 250, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Input level")
                    Spacer()
                    Text("\(Int(appState.audioMetrics.peak * 100))%")
                        .monospacedDigit()
                }
                ProgressView(value: Double(appState.audioMetrics.peak))
                    .tint(appState.audioMetrics.clipping ? .red : .accentColor)
                HStack(spacing: 14) {
                    Text("RTF \(appState.asrMetrics.realtimeFactor, format: .number.precision(.fractionLength(2)))")
                    Text("Overruns \(appState.audioMetrics.ringBufferOverruns)")
                    if appState.asrMetrics.droppedUtteranceCount > 0 {
                        Text("ASR drops \(appState.asrMetrics.droppedUtteranceCount)")
                            .foregroundStyle(.orange)
                    }
                    if let latency = appState.asrMetrics.finalLatency {
                        Text("Final \(latency, format: .number.precision(.fractionLength(2)))s")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 360)

            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Label("Local / offline", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .frame(maxWidth: 400)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var overlayWorkspace: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 24)
            Image(systemName: "captions.bubble")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text("Subtitles are rendered in the local web overlay")
                .font(.title3.weight(.semibold))
            Text("This Mac app keeps capture, ASR, translation, history, and export controls. Live subtitle text is not rendered in SwiftUI.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)

            if let url = appState.subtitleOverlayURL {
                VStack(spacing: 8) {
                    Text(url.absoluteString)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy URL", systemImage: "doc.on.doc") {
                            appState.copySubtitleOverlayURL()
                        }
                        Button("Open overlay", systemImage: "arrow.up.forward.app") {
                            appState.openSubtitleOverlay()
                        }
                    }
                }
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text(appState.subtitleOverlayStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("The page has a transparent background for OBS/browser sources. A normal browser window may still have its own opaque window chrome.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 580)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modelStateText: String {
        switch appState.modelState {
        case .unloaded: "Model: not loaded"
        case .loading: "Model: loading"
        case .loaded(let name): "Model: \(name)"
        case .unavailable(let message), .failed(let message): "Model: \(message)"
        }
    }

    private func historyMetadata(_ session: TranscriptionSession) -> String {
        let modelName = session.asrModelName ?? "No model"
        return "\(session.audioSourceType.displayName) · \(session.targetLanguage.uppercased()) · \(modelName)"
    }
}

private struct SettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.title2)
            GroupBox("Realtime ASR") {
                Grid(alignment: .leading, verticalSpacing: 10) {
                    GridRow {
                        Text("Partial interval")
                        Stepper(value: $appState.realtimeConfiguration.partialInterval, in: 0.4...2.0, step: 0.1) {
                            Text("\(appState.realtimeConfiguration.partialInterval, format: .number.precision(.fractionLength(1))) seconds")
                        }
                    }
                    GridRow {
                        Text("Final silence")
                        Stepper(value: $appState.realtimeConfiguration.finalSilence, in: 0.4...2.0, step: 0.1) {
                            Text("\(appState.realtimeConfiguration.finalSilence, format: .number.precision(.fractionLength(1))) seconds")
                        }
                    }
                    GridRow {
                        Text("Rolling window")
                        Stepper(value: $appState.realtimeConfiguration.rollingWindow, in: 2...12, step: 1) {
                            Text("\(appState.realtimeConfiguration.rollingWindow, format: .number.precision(.fractionLength(0))) seconds")
                        }
                    }
                    GridRow {
                        Text("Minimum speech")
                        Stepper(value: $appState.realtimeConfiguration.minimumValidSpeech, in: 0.1...1.0, step: 0.05) {
                            Text("\(appState.realtimeConfiguration.minimumValidSpeech, format: .number.precision(.fractionLength(2))) seconds")
                        }
                    }
                    GridRow {
                        Text("Max utterance")
                        Stepper(value: $appState.realtimeConfiguration.maximumUtteranceDuration, in: 5...45, step: 1) {
                            Text("\(appState.realtimeConfiguration.maximumUtteranceDuration, format: .number.precision(.fractionLength(0))) seconds")
                        }
                    }
                }
                .padding(.top, 4)
                .disabled(appState.isRunning)
            }
            GroupBox("Local subtitle overlay") {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, verticalSpacing: 8) {
                        GridRow {
                            Text("Display delay")
                            Stepper(value: $appState.subtitleDisplayDelay, in: 0...60, step: 0.5) {
                                Text("\(appState.subtitleDisplayDelay, format: .number.precision(.fractionLength(1))) seconds")
                            }
                        }
                    }
                    Text("Positive delay is measured from the end of captured speech. It only delays final subtitle presentation; it does not change audio capture, ASR, translation, saved timestamps, or exports. Changes apply to captions finalized after the adjustment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let url = appState.subtitleOverlayURL {
                        HStack {
                            Text(url.absoluteString)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Spacer()
                            Button("Copy") { appState.copySubtitleOverlayURL() }
                            Button("Open") { appState.openSubtitleOverlay() }
                        }
                    } else {
                        Text(appState.subtitleOverlayStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            GroupBox("Local dependencies") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Choose whisper.cpp CLI…") { appState.chooseWhisperCLI() }
                    Button("Import GGUF model…") { appState.importModel() }
                    if let whisperCLIURL = appState.whisperCLIURL {
                        Label("CLI: \(whisperCLIURL.lastPathComponent)", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help(whisperCLIURL.path)
                    } else {
                        Label("No whisper.cpp CLI selected", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Audio and text remain on this Mac. The app does not download model weights or use cloud ASR/translation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                .disabled(appState.isRunning)
            }
            GroupBox("Energy VAD fallback") {
                Grid(alignment: .leading, verticalSpacing: 10) {
                    GridRow {
                        Text("Speech threshold")
                        Stepper(value: $appState.vadConfiguration.speechThreshold, in: 0.005...0.2, step: 0.005) {
                            Text("\(appState.vadConfiguration.speechThreshold, format: .number.precision(.fractionLength(3)))")
                        }
                    }
                    GridRow {
                        Text("Release threshold")
                        Stepper(value: $appState.vadConfiguration.releaseThreshold, in: 0.002...0.15, step: 0.003) {
                            Text("\(appState.vadConfiguration.releaseThreshold, format: .number.precision(.fractionLength(3)))")
                        }
                    }
                }
                .padding(.top, 4)
                .disabled(appState.isRunning)
            }
            GroupBox("Glossary") {
                VStack(alignment: .leading, spacing: 8) {
                    if appState.glossaryEntries.isEmpty {
                        Text("Add names, abbreviations, or domain terms for local ASR correction and final translation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.glossaryEntries) { entry in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.canonicalText).font(.caption.weight(.semibold))
                                    Text(entry.spokenForms.joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    appState.removeGlossaryEntry(id: entry.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("Remove glossary term")
                            }
                        }
                    }
                    TextField("Spoken forms, separated by commas", text: $appState.newGlossarySpokenForms)
                    TextField("Canonical text", text: $appState.newGlossaryCanonicalText)
                    TextField("Preferred \(appState.targetLanguage.displayName) translation (optional)", text: $appState.newGlossaryTranslation)
                    HStack {
                        Spacer()
                        Button("Add glossary term") { appState.addGlossaryEntry() }
                            .disabled(
                                appState.newGlossarySpokenForms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || appState.newGlossaryCanonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                    }
                }
                .padding(.top, 4)
                .disabled(appState.isRunning)
            }
            GroupBox("Permissions and dataset") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Request Screen Recording permission") { appState.requestScreenRecordingPermission() }
                    Toggle("Enable dataset export workflow", isOn: $appState.saveDataset)
                    if appState.saveDataset {
                        Text("Privacy: audio is exported only for final utterances you explicitly mark Approved. Do not export personal or copyrighted speech without consent.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)
                .disabled(appState.isRunning)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}
