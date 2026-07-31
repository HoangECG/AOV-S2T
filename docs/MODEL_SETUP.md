# Model setup

## Non-negotiable privacy boundary

No model weight is committed to this repository or downloaded by the macOS app.
A user supplies a local model file and a local whisper.cpp CLI. The app then
runs inference on-device; it has no cloud ASR fallback.

The current ASRModelManager accepts files with .gguf or legacy .bin extensions
and copies them into the app's Application Support models directory. An extension
check is not proof of compatibility: the configured CLI must be able to load the
file. Settings exposes local import and CLI-selection actions. The selected CLI
path is presently session configuration, so revalidate it at each use and do
not assume it survives a move, replacement, or permission change.

## Build a compatible local CLI

WhisperCppEngine invokes a local executable with model, WAV input, Vietnamese
language, TXT output, and optional prompt arguments. Build it from a verified
local whisper.cpp checkout:

~~~sh
Scripts/build_whisper_xcframework.sh \
  --source Vendor/whisper.cpp \
  --output .local/bin/whisper-cli
~~~

The script name is retained for the project checklist, but the present Swift
Package uses a CLI adapter and does not link an XCFramework. It will not clone
source or download a model. CMake is required.

The repository records whisper.cpp v1.8.3 at
`2eeeba56e9edd762b4b38467bab96c2517163158` in
Vendor/whisper.cpp/REVISION, and bootstrap verifies that exact checkout. This
host has not fetched the vendor source or completed a CLI build, so it makes no
claim of a successful local whisper.cpp integration run.

## Obtain a model deliberately

For a small public smoke-test model, inspect the dry run first:

~~~sh
Scripts/download_test_model.sh --model tiny
Scripts/download_test_model.sh --model tiny --run
~~~

The second command explicitly contacts the configured public model URL and saves
weights under .local/models, outside source control. Review the model license,
origin, checksum, and intended language coverage before use. Use --sha256 when a
trusted publisher provides a checksum.

For realistic Vietnamese evaluation, source a multilingual Whisper-compatible
model legally and keep it outside Git. Importing or benchmarking a model is not
a claim that it is accurate for a particular accent, room, or glossary.

## Compatibility and candidate models

| Candidate | Intended use | Status in this checkout |
| --- | --- | --- |
| Whisper small multilingual | Baseline accuracy/latency benchmark | Not bundled or benchmarked |
| Whisper medium multilingual | Higher-accuracy benchmark on larger-memory hardware | Not bundled or benchmarked |
| Whisper large-v3-turbo, quantized | Resource-dependent benchmark | Not bundled or benchmarked |
| Fine-tuned Whisper checkpoint | Domain/voice experiment | Must be converted and independently verified |
| PhoWhisper or another HF model | Research candidate | Do not assume whisper.cpp conversion compatibility |

Do not label any of these as tested until a real model, CLI revision, input WAV,
machine profile, and measured result are recorded together.

## Smoke test before app integration

Use a non-sensitive local WAV file to verify the exact CLI syntax that the app
will invoke. The exact supported flags depend on the pinned revision.

~~~sh
.local/bin/whisper-cli \
  -m /path/to/model.gguf \
  -f /path/to/16k-mono.wav \
  -l vi \
  -otxt \
  -of /tmp/macspeechtranslator-smoke \
  -nt
~~~

Confirm that the CLI exits successfully and creates a readable TXT file. Then
configure WhisperCppEngine with the CLI URL, import the model through
ASRModelManager, and check that a final transcription completes locally. Missing
CLI/model, unreadable files, or nonzero CLI exits are surfaced as unavailable
errors; they do not select MockASREngine.

## Quantization, Metal, and Core ML

Quantization can reduce memory use and latency but can degrade recognition. The
format and quantizer must match the exact CLI revision. Keep the original model,
conversion command, quantization type, CLI commit, model hash, and held-out
evaluation report together.

The build script passes GGML_METAL=ON to CMake, but that is only a build
configuration. It is not evidence that Metal acceleration is active or faster
on a particular machine. Core ML support is likewise not integrated by the
Swift Package today. Record actual chip, unified memory, audio duration,
processing duration, realtime factor, and peak memory before publishing claims
about performance or RAM.

## Convert a fine-tuned model cautiously

The offline wrapper in tools/training/export_model.py requires a full Hugging
Face checkpoint with model_type equal to whisper and a local conversion program:

~~~sh
python3 tools/training/export_model.py \
  --input-dir /models/aov-whisper-v1 \
  --converter Vendor/whisper.cpp/convert-hf-to-gguf.py \
  --output /models/aov-whisper-v1.gguf
~~~

Without --run it only validates and prints the command. Inspect that command
against the converter's own help for the pinned whisper.cpp revision. Add --run
only when the interface is confirmed. A LoRA adapter is not a standalone
checkpoint; merge it into a full Whisper model first. Successful conversion is
not enough: run the CLI smoke test and a held-out WER/CER benchmark before
importing it into the app.

## Model record

For every deployed local model, maintain a small non-sensitive record containing:

- model display name and source/license;
- SHA-256 of the model file;
- whisper.cpp tag and verified commit;
- CLI build command and platform;
- language, prompt/glossary version, and decoding configuration;
- test dataset version, seed, WER/CER, and benchmark machine;
- known limitations and date of evaluation.

See [TRAINING.md](TRAINING.md) for data and evaluation workflow, and
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) for load/inference failures.
