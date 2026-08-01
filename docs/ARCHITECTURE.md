# Architecture

## Scope and current status

MacSpeechTranslator is a Swift 6 macOS Swift Package, opened directly in Xcode
or built with Swift. Its production goal is local Vietnamese ASR followed by
final-only local translation. Audio and transcript content must not be sent to a
cloud service by the application.

The package currently provides native audio foundations, protocol boundaries,
Energy VAD fallback, endpointing, realtime partial/final coordination, text
processing, final-only translation coordination, SQLite persistence, exporters,
and a local whisper-cli adapter. AppState and MainView assemble these local
services into source/model controls, a loopback-only browser subtitle overlay,
history, local export, and settings. This document distinguishes implemented
behavior from unverified hardware and model integration so an unavailable
component is never mistaken for a silent mock.

## Target data flow

~~~mermaid
flowchart LR
    input[Microphone / soundcard] --> capture[Audio input source]
    screen[ScreenCaptureKit system audio] --> capture
    capture --> ring[Bounded ring buffer]
    ring --> worker[Processing worker]
    worker --> format[Channel select/downmix + 16 kHz mono Float32]
    format --> vad[VAD + endpoint detector]
    vad --> partial[Rolling partial ASR]
    partial --> stabilize[Transcript stabilizer]
    stabilize --> endpoint{Endpoint?}
    endpoint -- no --> partial
    endpoint -- yes --> final[Final ASR for utterance]
    final --> normalize[Vietnamese normalization + segmentation]
    normalize --> glossary[Glossary correction]
    glossary --> translate[Final-only local translation]
    glossary --> store[Session / audio persistence]
    translate --> store
    store --> export[TXT / JSON / SRT / VTT / dataset export]
    translate --> overlay[127.0.0.1 transparent web overlay]
    overlay --> browser[Browser / OBS source]
    store --> ui[SwiftUI controls and history]
~~~

The current source includes AudioInputSource, AudioDeviceProviding,
AudioResampling, VoiceActivityDetecting, ASREngine, TranscriptStabilizing,
SentenceFinalizing, TextNormalizing, TranslationEngine, TranscriptRepository,
AudioRecordingRepository, GlossaryRepository, and TranscriptExporting. They are the
dependency-inversion boundary; SwiftUI must depend on coordinators and
protocols, not Core Audio or whisper.cpp directly.

## Implemented boundaries

| Area | Current implementation | Explicit limit |
| --- | --- | --- |
| Microphone / device discovery | Core Audio device enumeration, selected-device AVAudioEngine input, and a `kAudioDevicePropertyDeviceIsAlive` listener | It is not a full AUHAL implementation; real device-unplug validation remains required. |
| System audio | Audio-only ScreenCaptureKit capture for a display or application, excluding this app's own audio and safely ending on stream failure | Requires Screen Recording permission and real hardware validation. |
| Buffering / format | Bounded AudioRingBuffer plus bounded newest-only audio streams, channel mixer, AVAudioConverter-preferred resampler, level meter, pre-roll buffer, session-relative timestamps | Benchmark the selected converter path on target hardware; the fallback is not a production-quality music/noise claim. |
| VAD / endpointing | Adaptive EnergyVADFallback and endpoint decisions combining silence, stability, punctuation, and duration | SileroVADAdapter is intentionally unavailable until a real local integration is supplied. |
| ASR | WhisperCppEngine invokes a configured local whisper-cli with a user-imported GGUF/legacy BIN model; the selected CLI path is persisted/revalidated; RealtimeASRCoordinator produces rolling partial revisions and final utterances | No binary or cloud fallback is bundled; a CLI/model smoke test is not a substitute for microphone and accuracy validation. |
| Transcript | Stabilizer, Vietnamese normalizer/segmenter, sentence finalizer, controlled glossary correction, persisted local final segments and glossary editor | History/export administration remains in SwiftUI; live text is rendered only by the local overlay. |
| Translation | Final-only ordered coordinator, glossary placeholders/cache, Apple Translation availability checks | Apple Translation inference intentionally reports unavailable on macOS 15; the current programmatic session path is macOS 26+. |
| Subtitle display | Native `NWListener` bound to `127.0.0.1`, embedded transparent HTML, latest in-memory JSON snapshot, final-sentence presentation delay | The page is intended for browser/OBS sources; ordinary browser window chrome is not made transparent by CSS. No LAN, history, audio, or control endpoint is served. |
| Storage / export | Local SQLite sessions, local glossary/preferences, optional WAV recorder with session-delete cleanup, one-row-per-approved-utterance dataset exporter, TXT/JSON/SRT/VTT, history/export UI | Real user workflows and dataset retention/privacy behavior need validation. |
| Model files | ASRModelManager copies selected model files to Application Support; settings UI exposes local import/CLI selection and persists/revalidates the selected CLI path | A moved, replaced, or non-executable CLI is cleared at launch and must be selected again. |

## Threading and ownership

| Owner | Responsibility | Must not do |
| --- | --- | --- |
| Core Audio/ScreenCaptureKit callback | Copy Float32 samples into the bounded ring buffer | Run ASR, translation, persistence, resampling, or SwiftUI updates. |
| Source drain queue | Read a short frame into an eight-frame newest-only stream and report drops | Block on model inference. |
| Processing task/actor | Downmix, resample, level measurement, VAD, pre-roll, and endpointing | Touch views directly. |
| ASR actor | One cancellable local inference at a time; model lifecycle and temporary WAV cleanup | Publish raw process state across an unsafe boundary. |
| Transcript/translation coordinator | Revision replacement, finalization, normalization, cache/order management | Translate partial text. |
| Main actor | View/control state and presentation-only overlay scheduling | Perform audio DSP or inference. |

AudioFrame and configuration/model values are Sendable. Existing mutable audio
sources use a short NSLock around ring-buffer access and retain no lock while
draining or doing DSP. The intended steady state is one producer and one
consumer per source; overruns deliberately drop the oldest samples so live audio
prefers recency. Metrics must surface that loss.

## Partial versus final transcript contract

Whisper is utterance-oriented rather than a frame-native streaming engine. The
target coordinator starts an utterance from VAD/pre-roll, periodically runs
rolling-window inference, and replaces a single partial revision. It must not
append successive partial strings.

Only an endpointed utterance receives final inference. A valid VAD utterance
without a completed partial still receives final inference, so short speech is
not silently discarded. The final result is
normalized, segmented, persisted, and eligible for translation. A partial text
is ephemeral; it is neither sent to translation nor stored as the production
record. RealtimeASRCoordinator exposes separate partial/final events and
cancels a stale partial before final inference; AppState persists only final
segments and sends only those segments to TranslationCoordinator.
When final inference is saturated, one newest final utterance may wait; a
replacement is surfaced as an error event and a dropped-utterance metric rather
than hidden.

## Local overlay timing and boundary

`AppState` remains the single consumer of `RealtimeASRCoordinator.eventStream`.
It publishes a final, persisted sentence to `LocalSubtitleOverlayServer` only
after final-only translation has been attempted, so opening a browser page never
creates a competing ASR stream consumer. `TranscriptEvent.captureEndUptime`
carries a non-persisted monotonic timestamp from capture. The presentation
scheduler uses the end time of each segmented sentence plus the user-selected
delay; no exported/session timestamp changes. If recognition or translation is
already later than that deadline, the caption is published immediately.

The embedded page polls a bounded latest-subtitle JSON snapshot. Polling avoids
per-client stream queues and makes a browser/OBS reconnect receive only current
state, not a transcript backlog. The listener binds explicitly to
`127.0.0.1` on an OS-assigned port and exposes only `GET /overlay`,
`GET /subtitle`, and `GET /health`. It sends no external assets or CORS headers
and returns `Cache-Control: no-store`, CSP, and `X-Content-Type-Options:
nosniff` headers. Rendering uses DOM `textContent`.

## Dependency graph

~~~mermaid
flowchart TD
    app[MacSpeechTranslatorApp] --> core[MacSpeechTranslatorCore]
    core --> protocols[Core models + protocols]
    audio[Audio] --> protocols
    vad[VAD] --> protocols
    asr[ASR] --> protocols
    transcript[Transcript] --> protocols
    translation[Translation] --> protocols
    storage[Storage / export] --> protocols
    audio --> frameworks[AVFoundation / CoreAudio / ScreenCaptureKit]
    asr --> cli[User-configured local whisper-cli]
    cli --> model[User-imported GGUF or supported legacy BIN]
~~~

MacSpeechTranslatorCore may be unit-tested with MockASREngine and fake sources.
Production dependency assembly must never select a mock merely because a model
or CLI is missing; it should surface an unavailable state instead.

## Why whisper.cpp is behind a CLI adapter

The app needs a reproducible native ASR path without committing model weights or
opaque binaries. The adapter writes temporary local WAV input, invokes a
configured whisper-cli, reads its local output, supports cancellation by
terminating the process, and cleans its temporary directory. This is less
efficient than an in-process bridge, but keeps the Swift Package buildable while
the native dependency is not vendored.

The repository pins whisper.cpp v1.8.3 at
`2eeeba56e9edd762b4b38467bab96c2517163158` in
Vendor/whisper.cpp/REVISION. This checkout does not vendor source by default;
Scripts/bootstrap.sh --fetch-whisper verifies that exact source commit before a
CLI build. Run the CLI smoke tests in [MODEL_SETUP.md](MODEL_SETUP.md) before
shipping. The script named
build_whisper_xcframework.sh retains its checklist filename but deliberately
builds the CLI used by the current adapter; it does not claim an XCFramework
exists.

## Production app versus training tools

tools/ contains optional Python scripts for dataset validation, split,
fine-tuning, conversion preparation, and offline evaluation. They run outside
the app, are not embedded in its bundle, and never run automatically. Their
inputs and outputs may contain sensitive recordings, so datasets and model
checkpoints belong outside the repository. See [TRAINING.md](TRAINING.md).
