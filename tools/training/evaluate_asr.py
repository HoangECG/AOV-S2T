#!/usr/bin/env python3
"""Score saved ASR predictions or run an explicit local Whisper evaluation pass.

No model is downloaded by default and this script never uploads audio or text.
For repeatable benchmarks, keep --predictions produced by a prior local run.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys
from types import SimpleNamespace
from typing import Any

TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

from evaluation.evaluate_transcripts import build_report  # noqa: E402
from evaluation.records import RecordFormatError, read_records, write_json_atomic, write_jsonl_atomic  # noqa: E402
from manifest_utils import resolve_audio_path  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Evaluate offline Whisper predictions against a held-out manifest.")
    parser.add_argument("--reference-manifest", type=Path, required=True, help="Held-out canonical manifest.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--predictions", type=Path, help="Existing JSONL/CSV predictions to score.")
    source.add_argument("--model", help="Local Hugging Face Whisper model directory for an explicit inference pass.")
    parser.add_argument("--prediction-output", type=Path, help="Required with --model; where generated local predictions are saved.")
    parser.add_argument("--dataset-root", type=Path, help="Root for manifest audio paths (default: manifest parent).")
    parser.add_argument("--key", default="audio_filepath", help="Unique alignment field (default: audio_filepath).")
    parser.add_argument("--reference-field", default="text", help="Reference transcript field (default: text).")
    parser.add_argument("--prediction-field", default="prediction", help="Prediction field (default: prediction).")
    parser.add_argument("--language", default="vi", help="Whisper source language for local inference (default: vi).")
    parser.add_argument("--device", choices=("auto", "cpu", "mps", "cuda"), default="auto")
    parser.add_argument("--max-new-tokens", type=int, default=256)
    parser.add_argument("--max-records", type=int, help="Optional small benchmark cap; recorded in output.")
    parser.add_argument("--allow-model-download", action="store_true", help="Allow Transformers to fetch a named model explicitly.")
    parser.add_argument("--allow-unmatched", action="store_true", help="Score the key intersection instead of failing on mismatches.")
    parser.add_argument("--entities", type=Path, help="Optional named-entity vocabulary passed to transcript evaluation.")
    parser.add_argument("--report", type=Path, help="Optional JSON report path.")
    parser.add_argument("--overwrite", action="store_true", help="Allow replacing --prediction-output and/or --report.")
    return parser.parse_args()


def require_inference_dependencies() -> None:
    missing = [name for name in ("torch", "transformers", "soundfile") if importlib.util.find_spec(name) is None]
    if missing:
        raise RuntimeError(
            "Missing optional inference dependency/dependencies: "
            + ", ".join(missing)
            + ". Install tools/training/requirements.txt in a dedicated virtual environment."
        )


def resolve_device(torch_module: Any, requested: str) -> str:
    available = {
        "cuda": bool(torch_module.cuda.is_available()),
        "mps": bool(getattr(torch_module.backends, "mps", None) and torch_module.backends.mps.is_available()),
        "cpu": True,
    }
    if requested == "auto":
        return next(name for name in ("cuda", "mps", "cpu") if available[name])
    if not available[requested]:
        raise RuntimeError(f"Requested device '{requested}' is unavailable")
    return requested


def generate_predictions(args: argparse.Namespace) -> tuple[Path, dict[str, Any]]:
    if args.prediction_output is None:
        raise ValueError("--prediction-output is required when --model is used")
    if args.prediction_output.exists() and not args.overwrite:
        raise FileExistsError(f"Refusing to overwrite {args.prediction_output}; use --overwrite explicitly")
    if not args.allow_model_download and not Path(args.model).expanduser().is_dir():
        raise ValueError("--model must be an existing local directory unless --allow-model-download is explicit")
    require_inference_dependencies()
    import soundfile as sf
    import torch
    from transformers import WhisperForConditionalGeneration, WhisperProcessor

    device_name = resolve_device(torch, args.device)
    device = torch.device(device_name)
    local_files_only = not args.allow_model_download
    processor = WhisperProcessor.from_pretrained(args.model, local_files_only=local_files_only)
    model = WhisperForConditionalGeneration.from_pretrained(args.model, local_files_only=local_files_only)
    model.to(device)
    model.eval()
    forced_decoder_ids = processor.get_decoder_prompt_ids(language=args.language, task="transcribe")
    dataset_root = (args.dataset_root or args.reference_manifest.parent).resolve()
    references = read_records(args.reference_manifest)
    if args.max_records is not None:
        if args.max_records <= 0:
            raise ValueError("--max-records must be positive")
        references = references[: args.max_records]
    predictions: list[dict[str, Any]] = []
    for row_number, record in enumerate(references, start=1):
        key = str(record.get(args.key, "")).strip()
        if not key:
            raise ValueError(f"reference row {row_number} has no '{args.key}' value")
        _, audio_path = resolve_audio_path(dataset_root, record.get("audio_filepath"))
        if not audio_path.is_file():
            raise FileNotFoundError(f"reference row {row_number}: audio file does not exist: {audio_path}")
        audio, sample_rate = sf.read(audio_path, dtype="float32", always_2d=False)
        if getattr(audio, "ndim", 1) != 1:
            raise ValueError(f"reference row {row_number}: expected mono audio, got shape {getattr(audio, 'shape', None)}")
        if sample_rate != 16_000:
            raise ValueError(f"reference row {row_number}: expected 16 kHz audio, got {sample_rate} Hz")
        input_features = processor.feature_extractor(audio, sampling_rate=sample_rate, return_tensors="pt").input_features
        with torch.inference_mode():
            generated_ids = model.generate(
                input_features.to(device), forced_decoder_ids=forced_decoder_ids, max_new_tokens=args.max_new_tokens
            )
        transcript = processor.batch_decode(generated_ids, skip_special_tokens=True)[0].strip()
        predictions.append({args.key: key, args.prediction_field: transcript})
    write_jsonl_atomic(args.prediction_output, predictions, overwrite=args.overwrite)
    return args.prediction_output, {"device": device_name, "generated_records": len(predictions), "model": args.model}


def make_evaluation_args(args: argparse.Namespace, predictions: Path) -> SimpleNamespace:
    return SimpleNamespace(
        reference=args.reference_manifest,
        hypothesis=predictions,
        key=args.key,
        reference_field=args.reference_field,
        hypothesis_field=args.prediction_field,
        entities=args.entities,
        allow_unmatched=args.allow_unmatched or args.max_records is not None,
        per_record=False,
    )


def main() -> int:
    args = parse_args()
    try:
        inference_metadata: dict[str, Any] | None = None
        predictions = args.predictions
        if args.model:
            predictions, inference_metadata = generate_predictions(args)
        assert predictions is not None
        report = build_report(make_evaluation_args(args, predictions))
        report["asr_evaluation"] = {
            "reference_manifest": str(args.reference_manifest),
            "predictions": str(predictions),
            "inference": inference_metadata,
        }
        if args.report:
            write_json_atomic(args.report, report, overwrite=args.overwrite)
        print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    except (OSError, RecordFormatError, RuntimeError, ValueError, FileExistsError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
