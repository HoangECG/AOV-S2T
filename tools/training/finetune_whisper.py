#!/usr/bin/env python3
"""Explicit, local fine-tuning entry point for Hugging Face Whisper checkpoints.

This is deliberately opt-in: without --run it performs a no-write preflight.
It does not download a model unless --allow-model-download is supplied and it
never treats the test split as training input.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import sys
from typing import Any

TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

from evaluation.metrics import corpus_error_rate  # noqa: E402
from evaluation.records import RecordFormatError, read_records, write_json_atomic  # noqa: E402
from manifest_utils import validate_record  # noqa: E402


DEPENDENCIES = ("torch", "transformers", "datasets", "accelerate", "soundfile")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Fine-tune a local Whisper checkpoint on session-isolated manifests.")
    parser.add_argument("--model", required=True, help="Local Whisper checkpoint directory by default.")
    parser.add_argument("--train-manifest", type=Path, required=True)
    parser.add_argument("--validation-manifest", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, help="Root for relative audio paths (default: each manifest's parent).")
    parser.add_argument("--output-dir", type=Path, required=True, help="New directory for checkpoints and final model.")
    parser.add_argument("--language", default="vi", help="Whisper language code (default: vi).")
    parser.add_argument("--device", choices=("auto", "cpu", "mps", "cuda"), default="auto")
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--num-train-epochs", type=float, default=3.0)
    parser.add_argument("--max-steps", type=int, default=-1, help="Positive value overrides epoch count.")
    parser.add_argument("--learning-rate", type=float, default=1e-5)
    parser.add_argument("--per-device-train-batch-size", type=int, default=2)
    parser.add_argument("--per-device-eval-batch-size", type=int, default=2)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=8)
    parser.add_argument("--eval-steps", type=int, default=250)
    parser.add_argument("--save-steps", type=int, default=250)
    parser.add_argument("--logging-steps", type=int, default=25)
    parser.add_argument("--early-stopping-patience", type=int, default=3)
    parser.add_argument("--max-train-samples", type=int, help="Optional deterministic development cap.")
    parser.add_argument("--max-validation-samples", type=int, help="Optional deterministic development cap.")
    parser.add_argument("--use-lora", action="store_true", help="Use PEFT LoRA adapters (requires peft).")
    parser.add_argument("--lora-r", type=int, default=16)
    parser.add_argument("--lora-alpha", type=int, default=32)
    parser.add_argument("--lora-dropout", type=float, default=0.05)
    parser.add_argument("--gradient-checkpointing", action="store_true")
    parser.add_argument("--fp16", action="store_true", help="Use FP16 only on CUDA; rejected on MPS/CPU.")
    parser.add_argument("--resume-from-checkpoint", type=Path, help="Resume a compatible checkpoint already inside output-dir.")
    parser.add_argument("--allow-model-download", action="store_true", help="Explicitly allow a Hugging Face model ID to be downloaded.")
    parser.add_argument("--skip-audio-validation", action="store_true", help="Skip WAV header checks during preflight (not recommended).")
    parser.add_argument("--run", action="store_true", help="Perform training. Without this flag the command is preflight-only.")
    return parser.parse_args()


def dependency_status(include_peft: bool) -> dict[str, bool]:
    names = (*DEPENDENCIES, *(("peft",) if include_peft else ()))
    return {name: importlib.util.find_spec(name) is not None for name in names}


def check_scalar_arguments(args: argparse.Namespace) -> None:
    positive_values = {
        "num_train_epochs": args.num_train_epochs,
        "learning_rate": args.learning_rate,
        "per_device_train_batch_size": args.per_device_train_batch_size,
        "per_device_eval_batch_size": args.per_device_eval_batch_size,
        "gradient_accumulation_steps": args.gradient_accumulation_steps,
        "eval_steps": args.eval_steps,
        "save_steps": args.save_steps,
        "logging_steps": args.logging_steps,
    }
    invalid = [name for name, value in positive_values.items() if value <= 0]
    if invalid:
        raise ValueError("must be positive: " + ", ".join(invalid))
    if args.max_steps == 0 or args.max_steps < -1:
        raise ValueError("--max-steps must be -1 or a positive integer")
    if args.early_stopping_patience < 0:
        raise ValueError("--early-stopping-patience cannot be negative")
    if any(value is not None and value <= 0 for value in (args.max_train_samples, args.max_validation_samples)):
        raise ValueError("sample caps must be positive when supplied")
    if args.fp16 and args.device in {"cpu", "mps"}:
        raise ValueError("--fp16 is supported by this script only with --device cuda or auto selecting CUDA")
    if args.early_stopping_patience and args.eval_steps != args.save_steps:
        raise ValueError("--eval-steps and --save-steps must match when early stopping is enabled")


def validate_manifest(
    manifest: Path, dataset_root: Path, *, skip_audio_validation: bool
) -> tuple[list[dict[str, Any]], list[str], set[str]]:
    records = read_records(manifest)
    errors: list[str] = []
    sessions: set[str] = set()
    for line, record in enumerate(records, start=1):
        issues, _ = validate_record(
            record,
            line=line,
            dataset_root=dataset_root,
            require_duration=True,
            require_approved=True,
            verify_audio=not skip_audio_validation,
            require_training_format=True,
        )
        errors.extend(f"{manifest}: row {issue.line} [{issue.code}] {issue.message}" for issue in issues if issue.level == "error")
        session = str(record.get("session_id", "")).strip()
        if not session:
            errors.append(f"{manifest}: row {line} has no session_id; cannot verify leakage-safe splits")
        else:
            sessions.add(session)
    if not records:
        errors.append(f"{manifest}: manifest is empty")
    return records, errors, sessions


def validate_local_whisper_model(model: str, allow_model_download: bool) -> str:
    if allow_model_download:
        return "deferred: explicit model download/remote identifier allowed"
    model_path = Path(model).expanduser()
    if not model_path.is_dir():
        raise ValueError("--model must be an existing local directory unless --allow-model-download is explicit")
    config_path = model_path / "config.json"
    if not config_path.is_file():
        raise ValueError("local --model has no config.json")
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValueError(f"local model config.json is invalid: {error.msg}") from error
    if config.get("model_type") != "whisper":
        raise ValueError(f"local model_type must be 'whisper', got {config.get('model_type')!r}")
    return "local Whisper config verified"


def preflight(args: argparse.Namespace) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    check_scalar_arguments(args)
    model_validation = validate_local_whisper_model(args.model, args.allow_model_download)
    train_root = (args.dataset_root or args.train_manifest.parent).resolve()
    validation_root = (args.dataset_root or args.validation_manifest.parent).resolve()
    train_records, train_errors, train_sessions = validate_manifest(
        args.train_manifest, train_root, skip_audio_validation=args.skip_audio_validation
    )
    validation_records, validation_errors, validation_sessions = validate_manifest(
        args.validation_manifest, validation_root, skip_audio_validation=args.skip_audio_validation
    )
    overlap = sorted(train_sessions & validation_sessions)
    errors = [*train_errors, *validation_errors]
    if overlap:
        errors.append(f"train and validation share {len(overlap)} session_id value(s), which risks data leakage")
    status = dependency_status(args.use_lora)
    report = {
        "mode": "run" if args.run else "preflight",
        "model": args.model,
        "allow_model_download": args.allow_model_download,
        "model_validation": model_validation,
        "device_request": args.device,
        "train_manifest": str(args.train_manifest),
        "validation_manifest": str(args.validation_manifest),
        "train_records": len(train_records),
        "validation_records": len(validation_records),
        "train_sessions": len(train_sessions),
        "validation_sessions": len(validation_sessions),
        "session_overlap": len(overlap),
        "dependencies": status,
        "validation_errors": errors,
        "output_dir": str(args.output_dir),
    }
    if args.run and not all(status.values()):
        missing = ", ".join(name for name, installed in status.items() if not installed)
        errors.append(f"missing required dependencies: {missing}")
    if args.run and args.output_dir.exists() and any(args.output_dir.iterdir()) and args.resume_from_checkpoint is None:
        errors.append("output-dir exists and is non-empty; use a new output directory or an explicit resume checkpoint")
    if args.resume_from_checkpoint is not None:
        checkpoint = args.resume_from_checkpoint.resolve()
        output_dir = args.output_dir.resolve()
        if not checkpoint.is_dir():
            errors.append("resume checkpoint does not exist or is not a directory")
        else:
            try:
                checkpoint.relative_to(output_dir)
            except ValueError:
                errors.append("resume checkpoint must be inside --output-dir")
    report["validation_errors"] = errors
    return report, train_records, validation_records


def resolve_device(torch_module: Any, requested: str) -> str:
    available = {
        "cuda": bool(torch_module.cuda.is_available()),
        "mps": bool(getattr(torch_module.backends, "mps", None) and torch_module.backends.mps.is_available()),
        "cpu": True,
    }
    if requested == "auto":
        return next(name for name in ("cuda", "mps", "cpu") if available[name])
    if not available[requested]:
        raise RuntimeError(f"requested device '{requested}' is unavailable")
    return requested


@dataclass
class DataCollatorSpeechSeq2SeqWithPadding:
    processor: Any
    decoder_start_token_id: int

    def __call__(self, features: list[dict[str, Any]]) -> dict[str, Any]:
        input_features = [{"input_features": feature["input_features"]} for feature in features]
        batch = self.processor.feature_extractor.pad(input_features, return_tensors="pt")
        label_features = [{"input_ids": feature["labels"]} for feature in features]
        labels_batch = self.processor.tokenizer.pad(label_features, return_tensors="pt")
        labels = labels_batch["input_ids"].masked_fill(labels_batch.attention_mask.ne(1), -100)
        if labels.shape[1] and (labels[:, 0] == self.decoder_start_token_id).all().cpu().item():
            labels = labels[:, 1:]
        batch["labels"] = labels
        return batch


def run_training(
    args: argparse.Namespace, train_records: list[dict[str, Any]], validation_records: list[dict[str, Any]]
) -> dict[str, Any]:
    import torch
    from datasets import Audio, Dataset
    from transformers import (
        EarlyStoppingCallback,
        Seq2SeqTrainer,
        Seq2SeqTrainingArguments,
        WhisperForConditionalGeneration,
        WhisperProcessor,
        set_seed,
    )

    device_name = resolve_device(torch, args.device)
    if args.fp16 and device_name != "cuda":
        raise ValueError("--fp16 requires CUDA; auto selected a non-CUDA device")
    set_seed(args.seed)
    local_files_only = not args.allow_model_download
    processor = WhisperProcessor.from_pretrained(args.model, local_files_only=local_files_only)
    model = WhisperForConditionalGeneration.from_pretrained(args.model, local_files_only=local_files_only)
    model.generation_config.language = args.language
    model.generation_config.task = "transcribe"
    model.generation_config.forced_decoder_ids = None
    if args.gradient_checkpointing:
        model.config.use_cache = False
        model.gradient_checkpointing_enable()
    if args.use_lora:
        from peft import LoraConfig, TaskType, get_peft_model

        model = get_peft_model(
            model,
            LoraConfig(
                task_type=TaskType.SEQ_2_SEQ_LM,
                r=args.lora_r,
                lora_alpha=args.lora_alpha,
                lora_dropout=args.lora_dropout,
                target_modules=["q_proj", "v_proj"],
            ),
        )

    train_root = (args.dataset_root or args.train_manifest.parent).resolve()
    validation_root = (args.dataset_root or args.validation_manifest.parent).resolve()

    def dataset_from_records(records: list[dict[str, Any]], root: Path, limit: int | None) -> Any:
        selected = records[:limit] if limit is not None else records
        rows = [{"audio": str((root / str(record["audio_filepath"])).resolve()), "text": record["text"]} for record in selected]
        dataset = Dataset.from_list(rows).cast_column("audio", Audio(sampling_rate=16_000))

        def prepare_batch(batch: dict[str, Any]) -> dict[str, Any]:
            audio = batch["audio"]
            batch["input_features"] = processor.feature_extractor(
                audio["array"], sampling_rate=audio["sampling_rate"]
            ).input_features[0]
            batch["labels"] = processor.tokenizer(batch["text"]).input_ids
            return batch

        return dataset.map(prepare_batch, remove_columns=dataset.column_names, desc="Extracting Whisper features")

    train_dataset = dataset_from_records(train_records, train_root, args.max_train_samples)
    validation_dataset = dataset_from_records(validation_records, validation_root, args.max_validation_samples)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    config = {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()}
    config_path = args.output_dir / "training_config.json"
    if not config_path.exists():
        write_json_atomic(config_path, config, overwrite=False)
    training_kwargs: dict[str, Any] = {
        "output_dir": str(args.output_dir),
        "per_device_train_batch_size": args.per_device_train_batch_size,
        "per_device_eval_batch_size": args.per_device_eval_batch_size,
        "gradient_accumulation_steps": args.gradient_accumulation_steps,
        "learning_rate": args.learning_rate,
        "num_train_epochs": args.num_train_epochs,
        "max_steps": args.max_steps,
        "eval_strategy": "steps",
        "save_strategy": "steps",
        "eval_steps": args.eval_steps,
        "save_steps": args.save_steps,
        "logging_steps": args.logging_steps,
        "load_best_model_at_end": bool(args.early_stopping_patience),
        "metric_for_best_model": "wer",
        "greater_is_better": False,
        "predict_with_generate": True,
        "remove_unused_columns": False,
        "report_to": [],
        "fp16": args.fp16 and device_name == "cuda",
        "use_cpu": device_name == "cpu",
    }
    if device_name == "mps":
        training_kwargs["use_mps_device"] = True
    training_args = Seq2SeqTrainingArguments(**training_kwargs)

    def compute_metrics(prediction: Any) -> dict[str, float]:
        prediction_ids = prediction.predictions[0] if isinstance(prediction.predictions, tuple) else prediction.predictions
        label_ids = prediction.label_ids.copy()
        label_ids[label_ids == -100] = processor.tokenizer.pad_token_id
        predicted_text = processor.batch_decode(prediction_ids, skip_special_tokens=True)
        reference_text = processor.batch_decode(label_ids, skip_special_tokens=True)
        return {
            "wer": corpus_error_rate(reference_text, predicted_text, unit="word").value,
            "cer": corpus_error_rate(reference_text, predicted_text, unit="character").value,
        }

    callbacks = [EarlyStoppingCallback(early_stopping_patience=args.early_stopping_patience)] if args.early_stopping_patience else []
    trainer = Seq2SeqTrainer(
        args=training_args,
        model=model,
        train_dataset=train_dataset,
        eval_dataset=validation_dataset,
        data_collator=DataCollatorSpeechSeq2SeqWithPadding(processor, model.config.decoder_start_token_id),
        compute_metrics=compute_metrics,
        tokenizer=processor.feature_extractor,
        callbacks=callbacks,
    )
    trainer.train(resume_from_checkpoint=str(args.resume_from_checkpoint) if args.resume_from_checkpoint else None)
    metrics = trainer.evaluate()
    trainer.save_model()
    processor.save_pretrained(args.output_dir)
    trainer.save_state()
    return {"device": device_name, "metrics": metrics, "output_dir": str(args.output_dir)}


def main() -> int:
    args = parse_args()
    try:
        report, train_records, validation_records = preflight(args)
        if report["validation_errors"]:
            print(json.dumps(report, ensure_ascii=False, indent=2), file=sys.stderr)
            return 2
        if not args.run:
            print(json.dumps(report, ensure_ascii=False, indent=2))
            return 0
        result = run_training(args, train_records, validation_records)
        report["result"] = result
        report_path = args.output_dir / "training_report.json"
        if report_path.exists():
            suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            report_path = args.output_dir / f"training_report_resume_{suffix}.json"
        write_json_atomic(report_path, report, overwrite=False)
        print(json.dumps(report, ensure_ascii=False, indent=2, default=str))
        return 0
    except (OSError, RecordFormatError, RuntimeError, ValueError, FileExistsError, ImportError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
