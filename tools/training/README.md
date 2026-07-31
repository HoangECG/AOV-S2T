# Local Whisper training tools

These scripts are an offline companion to the macOS app. They are not shipped
inside the app and do not embed a Python runtime. Keep recordings, manifests,
checkpoints, and converted models outside Git.

## Setup

Use Python 3.10–3.12 in a dedicated environment. Apple Silicon users should
install a current macOS PyTorch wheel, then install the pinned packages:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r tools/training/requirements.txt
```

The scripts never download a model by default. A model download requires the
explicit `--allow-model-download` flag, while model conversion always requires
a local converter supplied by the user.

## Dataset contract

The expected dataset root contains WAV files and a JSONL manifest. The app's
dataset export already follows this shape.

```text
dataset/
├── audio/utterance_<uuid>.wav
└── manifest.jsonl
```

Each training row must include a relative `audio_filepath`, a non-empty `text`,
a positive `duration`, `session_id`, and `quality_label: "approved"`. The
default validator requires uncompressed 16 kHz mono 16-bit PCM WAV. `raw_text`
may be retained for analysis, but `text` should be the user-corrected transcript.

```json
{"audio_filepath":"audio/utterance_123.wav","text":"Hôm nay chúng ta kiểm tra hệ thống.","raw_text":"hôm nay chúng ta kiểm tra hệ thống","duration":2.34,"session_id":"session-42","language":"vi","quality_label":"approved"}
```

Do not put unreviewed speech into the approved manifest by default. Check for
personal information and recording consent before sharing any dataset.

## Prepare, validate, and split

`prepare_dataset.py` keeps only approved rows by default, selects
`corrected_text` before `text`, derives WAV duration, and does not copy audio.

```sh
python tools/training/prepare_dataset.py \
  --input-manifest exported/manifest.jsonl \
  --dataset-root exported \
  --output dataset/manifest.jsonl

python tools/training/validate_manifest.py \
  --manifest dataset/manifest.jsonl --dataset-root dataset --require-approved

python tools/training/split_dataset.py \
  --manifest dataset/manifest.jsonl --output-dir dataset/splits --seed 2026
```

The split tool groups by `session_id`, writes `train.jsonl`, `validation.jsonl`,
and `test.jsonl`, and refuses to create a split that puts a session in more than
one partition. Never train on `test.jsonl`.

## Fine-tune

First run the no-write preflight. It checks manifests, session overlap, paths,
and optional dependencies. It expects a local, full Hugging Face Whisper
checkpoint unless `--allow-model-download` is explicitly passed.

```sh
python tools/training/finetune_whisper.py \
  --model /models/whisper-small \
  --train-manifest dataset/splits/train.jsonl \
  --validation-manifest dataset/splits/validation.jsonl \
  --dataset-root dataset \
  --output-dir /models/aov-whisper-small-v1
```

Add `--run` only after reviewing the preflight. Checkpoints, the selected seed,
arguments, and final metrics are written to the output directory. The default
device selection is CUDA, then MPS, then CPU. MPS is useful for small experiments
but may be slower or hit unsupported PyTorch operations; use `--device cpu` for
diagnosis. CUDA can use `--device cuda --fp16`; do not request FP16 on MPS.

```sh
python tools/training/finetune_whisper.py \
  --model /models/whisper-small \
  --train-manifest dataset/splits/train.jsonl \
  --validation-manifest dataset/splits/validation.jsonl \
  --dataset-root dataset \
  --output-dir /models/aov-whisper-small-v1 \
  --use-lora --run
```

LoRA is optional and trains adapters, not a standalone model. Merge adapters
into a full Whisper checkpoint before attempting conversion. The script uses
early stopping by default and requires matching `--eval-steps` and
`--save-steps` so the best checkpoint is reproducible.

## Evaluate the held-out test split

Score saved predictions without loading a model:

```sh
python tools/training/evaluate_asr.py \
  --reference-manifest dataset/splits/test.jsonl \
  --predictions predictions.jsonl \
  --key audio_filepath --report reports/test.json
```

For an explicit local Transformers inference pass, give a local model and a
new output file. It loads each 16 kHz mono WAV locally and never uploads audio.

```sh
python tools/training/evaluate_asr.py \
  --reference-manifest dataset/splits/test.jsonl --dataset-root dataset \
  --model /models/aov-whisper-small-v1 \
  --prediction-output reports/test-predictions.jsonl \
  --report reports/test.json
```

The report includes WER, CER, number precision/recall/F1, sentence-boundary
precision/recall/F1, and named-entity scores if an entity list is supplied.

## Conversion for the macOS app

Do not assume that an arbitrary fine-tuned Hugging Face model converts to the
format accepted by the app's configured `whisper-cli`. Conversion depends on
the exact pinned whisper.cpp revision and model architecture. The wrapper makes
no such claim; it checks `model_type: whisper`, prints a command, and runs only
with `--run`.

```sh
python tools/training/export_model.py \
  --input-dir /models/aov-whisper-small-v1 \
  --converter Vendor/whisper.cpp/convert-hf-to-gguf.py \
  --output /models/aov-whisper-small-v1.gguf
```

First inspect the dry-run command against the converter's own `--help` for the
checked-out whisper.cpp revision. Then re-run with `--run`. Import the resulting
model into the app only after a held-out benchmark and a real `whisper-cli`
smoke test succeed.
