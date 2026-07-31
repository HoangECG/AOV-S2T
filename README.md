# MacSpeechTranslator

MacSpeechTranslator is a Swift 6 SwiftUI macOS app for local Vietnamese speech
transcription and final-only translation. Its audio, transcripts, local models,
and exported datasets stay on the Mac: there is no cloud ASR or hidden cloud
translation fallback.

This repository is a Swift Package rather than a generated `.xcodeproj`.
Open `Package.swift` directly in a full Xcode installation, or use the SwiftPM
commands below. A small script builds a local `.app` bundle from the package.

## Implemented MVP

- Core Audio input-device discovery, selected microphone/audio-interface input,
  channel choice/downmix, bounded ring buffer, 16 kHz mono Float32 processing,
  meter, and safe device-start failure state.
- Audio-only ScreenCaptureKit source listing/capture for display or listed app,
  with Screen Recording TCC checks and self-audio exclusion.
- Energy VAD fallback, pre-roll, endpointing, rolling partial replacement,
  single-inference coordination, and final utterance events.
- A real offline `whisper.cpp` CLI adapter when a user configures a locally
  built CLI and imports a compatible local GGUF model. No model or binary is
  bundled, and no production mock is selected when either is missing.
- Vietnamese normalization, sentence segmentation, glossary correction,
  persistent local glossary/settings, Apple Translation availability checks,
  and final-only ordered translation.
- Local SQLite session/history storage, transcript correction/quality labels,
  optional 16 kHz PCM WAV utterance recording, TXT/JSON/SRT/VTT export, and
  approved-only dataset WAV + JSONL export.
- Offline Python dataset preparation, session-safe split, evaluation, and
  fine-tuning/conversion-preflight tools under `tools/`.

## Requirements and local validation environment

The package declares macOS 15.0 minimum and targets Swift 6; this host is
arm64 macOS 26.6 with Apple Swift 6.3.3. It has Command Line Tools only, not a
full Xcode installation, so `xcodebuild` cannot run here. `swift build` and the
dependency-free core-check executable do run here. Install/select a compatible
full Xcode before doing an Xcode build, signing, sandbox, or hardware release
validation.

## Build and run

```sh
swift build
Scripts/build_app.sh
```

The second command prints the generated app location; open it with the printed
`open` command. In full Xcode, open `Package.swift`, select the
`MacSpeechTranslator` executable scheme, and build/run it.

## Tests

```sh
Scripts/run_tests.sh
```

It runs 20 deterministic Swift core checks and syntax/CLI checks for the
offline tools. It does not use microphone hardware, Screen Recording permission,
or model weights. See [docs/TEST_PLAN.md](docs/TEST_PLAN.md) for the required
manual device/model test matrix and benchmark protocol.

## Configure local ASR

The package pins whisper.cpp `v1.8.3` at commit
`2eeeba56e9edd762b4b38467bab96c2517163158`; weights are never committed.

```sh
Scripts/bootstrap.sh --fetch-whisper
Scripts/build_whisper_xcframework.sh --source Vendor/whisper.cpp --output .local/bin/whisper-cli
```

The current host does not have CMake, so the second command is not runnable
here. In the app, open Settings, choose that local `whisper-cli`, import a
compatible GGUF model, choose an input, then start. See
[docs/MODEL_SETUP.md](docs/MODEL_SETUP.md) before downloading or converting a
model.

## Permissions and audio sources

Microphone capture triggers macOS microphone consent using the bundled
`NSMicrophoneUsageDescription`. System audio requires Screen Recording consent;
use Settings → “Request Screen Recording permission”, then restart when macOS
asks. The app intentionally does not guess a Screen Recording `Info.plist` key
or deep-link to a non-contractual System Settings URL. Detailed recovery steps
are in [docs/PERMISSIONS.md](docs/PERMISSIONS.md).

Choose `Microphone / soundcard` to select a Core Audio input and channel/downmix.
Choose `System audio` to select a display or a ScreenCaptureKit-listed app.
Protected media, revoked TCC consent, a closed source, and a disconnected device
must be checked manually on the target machine.

## Export, privacy, and limits

Use Export to write a session as TXT, JSON, SRT, or VTT. Enable Record to save
final utterance WAV files locally; mark only consented, reviewed utterances as
**Approved** before creating a dataset export. Do not commit personal audio,
model weights, checkpoints, or exported datasets.

Recognition accuracy is model-, accent-, noise-, device-, and terminology-
dependent. This app makes no 100% accuracy claim. Use the training/evaluation
workflow and report WER/CER plus domain-specific entity/number/sentence metrics
before deploying a model.

Current known limits are deliberately visible: no in-process C/Objective-C++
whisper bridge is bundled (the local CLI adapter is used instead), Energy VAD is
not Silero, the selected CLI path is not yet persisted, and real model,
microphone, USB interface, system-audio, and Apple Translation language-pack
tests have not run on this host. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Next steps

1. Run the manual hardware/model matrix with a pinned CLI/model and record a
   benchmark report.
2. Replace the CLI boundary with a verified in-process whisper.cpp bridge if
   startup/temporary-file overhead is unacceptable.
3. Add a trained Silero VAD integration and validate noisy/music conditions.
4. Add model/CLI bookmarks and retention controls for a sandboxed signed build.
