# Training and evaluation

## Scope

Fine-tuning is an offline, opt-in workflow. The macOS app does not ship a Python
runtime and does not automatically run these tools. Training can improve a
specific domain, microphone, accent mix, or glossary, but it cannot justify a
claim of universal or 100% transcription accuracy.

The tools require a local dataset, an explicit local output path, and a local
Hugging Face Whisper checkpoint unless a model download is explicitly allowed.
They do not upload audio or transcript content.

## Dataset and correction workflow

1. Capture an utterance only after a person has opted into recording.
2. Keep ASR raw text separately from the user-facing corrected text.
3. Let a reviewer correct the transcript and apply quality_label: approved only
   when it is suitable for training.
4. Export 16 kHz mono PCM WAV and metadata locally.
5. Run validation before a dataset is split or used by a trainer.
6. Version the manifest and the review policy, not private audio in Git.

The canonical manifest is JSONL. Each row has a path relative to the dataset
root and a transcript that a reviewer has approved.

~~~json
{"audio_filepath":"audio/utterance_123.wav","text":"Hôm nay chúng ta kiểm tra hệ thống.","raw_text":"hôm nay chúng ta kiểm tra hệ thống","duration":2.34,"speaker_id":"optional","session_id":"session-42","language":"vi","device":"USB microphone","model":"baseline","quality_label":"approved"}
~~~

The local validators require a non-empty text value, positive duration, an audio
path that cannot escape the dataset root, and—by default—an uncompressed
16 kHz mono 16-bit PCM WAV. They warn when duration metadata differs from the
WAV header. No script copies or deletes source audio as part of preparation.

## Prepare and validate

~~~sh
python3 tools/training/prepare_dataset.py \
  --input-manifest export/manifest.jsonl \
  --dataset-root export \
  --output dataset/manifest.jsonl

python3 tools/training/validate_manifest.py \
  --manifest dataset/manifest.jsonl \
  --dataset-root dataset \
  --require-approved \
  --report reports/manifest-validation.json
~~~

Preparation uses corrected_text, then text, then normalized_text unless a field
is explicitly selected. It keeps approved rows by default and refuses to
overwrite output without --overwrite. Use --dry-run to inspect its report and
--strict to prevent writing a partial result if any input row is rejected.

## Leakage-safe split

Utterances from one recording session can share speaker, room noise, context,
and adjacent wording. A random utterance split therefore gives unrealistically
optimistic validation and test results. Split by session:

~~~sh
python3 tools/training/split_dataset.py \
  --manifest dataset/manifest.jsonl \
  --output-dir dataset/splits \
  --group-field session_id \
  --train-ratio 0.8 --validation-ratio 0.1 --test-ratio 0.1 \
  --seed 2026
~~~

The tool refuses missing session IDs and enforces that a group appears in one
split only. It saves the seed, ratios, record counts, group counts, and duration
in split_metadata.json. Keep test.jsonl sealed: it is for final evaluation only,
not early stopping, prompt tuning, model selection, or error-driven retraining.

## Fine-tune local Whisper

Create a dedicated virtual environment and install the pinned dependencies in
tools/training/requirements.txt. The pins are for reproducibility; refresh them
deliberately and record test results when upgrading.

Run a preflight first. It does not write a model or begin optimization.

~~~sh
python3 tools/training/finetune_whisper.py \
  --model /models/whisper-small \
  --train-manifest dataset/splits/train.jsonl \
  --validation-manifest dataset/splits/validation.jsonl \
  --dataset-root dataset \
  --output-dir /models/aov-whisper-small-v1
~~~

The preflight validates both manifests, requires approved records and session
isolation, checks model/path policy, and reports dependencies. Add --run only
after the report is clean:

~~~sh
python3 tools/training/finetune_whisper.py \
  --model /models/whisper-small \
  --train-manifest dataset/splits/train.jsonl \
  --validation-manifest dataset/splits/validation.jsonl \
  --dataset-root dataset \
  --output-dir /models/aov-whisper-small-v1 \
  --use-lora --run
~~~

The trainer stores arguments, seed, checkpoints, state, and validation metrics
inside the supplied output directory. It defaults to CUDA when available, then
Apple Silicon MPS, then CPU. Use CPU to diagnose an MPS-specific PyTorch error.
FP16 is allowed only on CUDA in this tool. LoRA is optional; it creates adapters
that must be merged before a standalone model conversion is attempted.

## Offline evaluation

Evaluate saved predictions against the held-out manifest without loading a
model:

~~~sh
python3 tools/training/evaluate_asr.py \
  --reference-manifest dataset/splits/test.jsonl \
  --predictions reports/test-predictions.jsonl \
  --key audio_filepath \
  --report reports/test.json
~~~

For broader transcript comparisons, use:

~~~sh
python3 tools/evaluation/evaluate_transcripts.py \
  --reference reference.jsonl \
  --hypothesis hypothesis.jsonl \
  --key utterance_id \
  --entities glossary-canonical.txt \
  --output reports/transcript-quality.json
~~~

The scripts calculate:

| Metric | Meaning |
| --- | --- |
| WER | Corpus word-level Levenshtein distance divided by reference words |
| CER | Corpus character-level Levenshtein distance divided by reference characters |
| Named entity accuracy | Micro precision/recall/F1 for supplied canonical entity occurrences |
| Number accuracy | Micro precision/recall/F1 for digit-form numbers and percentages |
| Sentence boundary | Precision/recall/F1 for punctuation-derived boundaries after matching token runs |

Comparison normalizes Unicode to NFC, whitespace, and case for metrics while
preserving Vietnamese diacritics. It does not rewrite raw data, spell out
numbers, or perform glossary replacement. Record unmatched rows instead of
silently scoring a partial intersection; the evaluator refuses mismatched keys
unless --allow-unmatched is explicit.

## Conversion and deployment

Use export_model.py only with a full Whisper checkpoint and a converter for the
exact pinned whisper.cpp revision. It is a wrapper, not proof that every
Hugging Face model is convertible.

~~~sh
python3 tools/training/export_model.py \
  --input-dir /models/aov-whisper-small-v1 \
  --converter Vendor/whisper.cpp/convert-hf-to-gguf.py \
  --output /models/aov-whisper-small-v1.gguf
~~~

The default operation is a dry run. Inspect the generated command, then add
--run. Verify the result with the actual local whisper-cli and a held-out
benchmark before app import. See [MODEL_SETUP.md](MODEL_SETUP.md).

## Versioning and retention

For each experiment, retain a non-sensitive experiment card with:

- dataset manifest identifier, correction policy, split seed, and session counts;
- base model source/license, source revision, and output file hashes;
- exact dependency versions, command, device, and training arguments;
- validation and untouched test WER/CER plus entity/number error analysis;
- whisper.cpp commit, converter command, quantization, CLI smoke result;
- known failure modes, date, reviewer, and approval for deployment.

Store audio, checkpoints, models, and reports outside Git. Delete data according
to the consent/retention policy. See [PERMISSIONS.md](PERMISSIONS.md).

