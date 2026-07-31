# Troubleshooting

## Start with the exact state

Collect the app's visible source/model/VAD status, macOS version, Swift package
command, and non-sensitive error text. Do not attach recordings, full
transcripts, model files, or absolute private paths to an issue by default.

~~~sh
Scripts/bootstrap.sh
Scripts/run_tests.sh
~~~

These commands establish toolchain/package status without downloading a model.
Add --resolve to bootstrap only when dependency resolution is intentionally
allowed.

## Audio input problems

| Symptom | Check | Safe response |
| --- | --- | --- |
| No microphone prompt | Confirm the release bundle has the microphone usage description and has actually requested audio authorization | Relaunch, then inspect Privacy & Security > Microphone |
| Permission denied | macOS TCC state can persist after a denial | Enable the app in System Settings, quit/reopen if prompted; do not bypass TCC |
| USB device missing | Cable, power, macOS Audio MIDI Setup, then re-enumerate devices | Select an explicit replacement; never silently fall back to a different microphone |
| Capture starts then stops | Inspect the source state and device/ScreenCaptureKit error | Stop cleanly, refresh sources, and preserve only completed final utterances |
| Meter moves but ASR is poor | Inspect selected channel, clipping, native rate, and downmix | Test one known channel; reduce gain and use a short clean WAV benchmark |
| Overrun count rises | Processing is not keeping up or buffer capacity is too low | Reduce work outside callback, cancel stale partial inference, and record the loss in diagnostics |

The present source has start-failure and ScreenCaptureKit stream handling but no
complete Core Audio hot-unplug listener yet. Treat unplug during a long session
as a manual hardening test.

## System audio problems

ScreenCaptureKit requires Screen & System Audio Recording consent (called Screen
Recording on some releases). Enable the app in Privacy & Security, quit/reopen
if macOS requests it, and retry source enumeration.

If an application source is absent, it may be an OS/ScreenCaptureKit limitation,
not an app error. Try a display source. The app intentionally excludes its own
audio where the filter supports it; absence of self-audio can therefore be
expected.

## Model and local ASR problems

| Symptom | Check | Response |
| --- | --- | --- |
| Model missing/unreadable | File still exists and is readable after import | Re-import the file; do not use a symlink/path that disappears |
| CLI unavailable | Configured executable exists and has execute permission | Build the verified local CLI, then configure its URL explicitly |
| CLI exits nonzero | Exact CLI revision, model format, flags, and direct smoke command | Run the command from MODEL_SETUP.md; capture only non-sensitive stderr |
| Empty transcript | 16 kHz mono WAV, language vi, VAD endpoint, model capability | Test final inference on a short known WAV before debugging realtime logic |
| Slow/failing inference | Model size, quantization, unified memory, Metal build behavior | Benchmark a smaller model; do not claim acceleration without measurements |
| Fine-tuned model does not load | Conversion is architecture/revision-specific | Keep base/adapter metadata; verify converter output with local CLI before app import |

A missing model or CLI must result in an unavailable state. It must not silently
substitute MockASREngine or invoke a cloud ASR service.

## Dataset and evaluation problems

~~~sh
python3 tools/training/validate_manifest.py \
  --manifest dataset/manifest.jsonl --dataset-root dataset --require-approved
~~~

Common validation failures:

- audio_filepath is absolute or contains ..: make it a safe relative path under
  the dataset root;
- WAV is not 16 kHz mono 16-bit PCM: convert outside the app, preserve the
  original, then revalidate;
- duration differs: regenerate metadata from the actual WAV header;
- quality_label is not approved: review it before using it for training;
- session_id is absent: add a recording-session identifier before splitting.

The splitter intentionally rejects missing group IDs and does not randomize
individual utterances. If there are fewer sessions than requested nonempty
splits, collect more independent sessions rather than leaking rows.

If WER/CER unexpectedly improves dramatically, first confirm key alignment,
zero session overlap, an untouched test manifest, and no repeated audio paths.
The evaluator refuses mismatched record keys unless --allow-unmatched is
explicit.

## Python training problems

| Symptom | Response |
| --- | --- |
| Missing torch/transformers/datasets | Activate the intended virtual environment and install tools/training/requirements.txt |
| MPS error or instability | Retry the same preflight or small run with --device cpu; report PyTorch/macOS versions |
| CUDA requested but absent | Use --device auto or cpu; install a CUDA-capable PyTorch build on the server |
| Output directory not empty | Use a new directory or an explicit checkpoint inside that directory; do not overwrite experiment evidence |
| LoRA cannot convert | Merge adapters into a full Whisper checkpoint, then validate model_type and converter compatibility |
| Converter command differs | Inspect the exact pinned converter's help and pass an explicit command template; do not guess flags |

The training command is preflight-only until --run is supplied. Model downloads
are also disabled unless --allow-model-download is explicit.

## Transcript, translation, storage, and export

The package contains concrete realtime coordination, final-segment persistence,
exporters, final-only translation coordination, and SwiftUI controls for the
local workflow. If a user-facing build claims a control or state that is not
actually wired, treat that as a release blocker rather than hiding it with mock
data.

For a workflow failure, investigate in this order: final-event creation,
normalization, sentence boundary, glossary safety, final-only translation,
repository save, then exporter timestamp validation. Partial revisions must
never be persisted as separate permanent transcript lines or sent for
translation.

## What to include in a safe bug report

Include package commit, macOS/Swift version, app source/VAD/model state, device
class (not serial number), model version/hash prefix, and a redacted error.
Include a minimal synthetic WAV or generated transcript fixture only when its
license and consent are clear. Do not include raw recordings, credentials,
personal names, meeting content, or model weights.
