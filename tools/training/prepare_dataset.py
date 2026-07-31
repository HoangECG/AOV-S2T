#!/usr/bin/env python3
"""Create a canonical approved-training manifest without copying private audio.

The script reads an export from the app (or a compatible JSONL/CSV file), keeps
only review-approved utterances by default, and writes a new manifest.  Audio
files remain in place; their paths must already be relative to --dataset-root.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any
import wave

TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

from evaluation.metrics import canonical_text  # noqa: E402
from evaluation.records import RecordFormatError, read_records, write_jsonl_atomic  # noqa: E402
from manifest_utils import inspect_wav, resolve_audio_path, validate_record  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare a canonical local ASR-training manifest.")
    parser.add_argument("--input-manifest", type=Path, required=True, help="App-exported or compatible JSONL/CSV/TSV manifest.")
    parser.add_argument("--output", type=Path, required=True, help="New canonical manifest.jsonl path.")
    parser.add_argument(
        "--dataset-root",
        type=Path,
        help="Root for relative audio paths (default: input-manifest parent directory).",
    )
    parser.add_argument(
        "--text-field",
        default="auto",
        help="Transcript field to use, or 'auto' for corrected_text → text → normalized_text.",
    )
    parser.add_argument("--audio-field", default="audio_filepath", help="Input audio-path field (default: audio_filepath).")
    parser.add_argument("--default-language", default="vi", help="Language used when the source row omits language (default: vi).")
    parser.add_argument(
        "--approved-only",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Keep only quality_label=approved rows (default: true).",
    )
    parser.add_argument("--allow-nontraining-audio", action="store_true", help="Do not require 16 kHz mono 16-bit PCM WAV.")
    parser.add_argument("--strict", action="store_true", help="Fail without writing output if any input row is rejected.")
    parser.add_argument("--dry-run", action="store_true", help="Validate and report without writing a file.")
    parser.add_argument("--overwrite", action="store_true", help="Allow replacing an existing output manifest.")
    return parser.parse_args()


def choose_text(record: dict[str, Any], field: str) -> str:
    candidates = (field,) if field != "auto" else ("corrected_text", "text", "normalized_text")
    for candidate in candidates:
        value = record.get(candidate)
        if isinstance(value, str) and value.strip():
            return canonical_text(value)
    return ""


def canonical_row(
    record: dict[str, Any], args: argparse.Namespace, dataset_root: Path
) -> tuple[dict[str, Any] | None, str | None]:
    if args.approved_only and record.get("quality_label") != "approved":
        return None, "quality_label is not approved"
    try:
        relative_audio_path, absolute_audio_path = resolve_audio_path(dataset_root, record.get(args.audio_field))
    except ValueError as error:
        return None, str(error)
    text = choose_text(record, args.text_field)
    if not text:
        return None, "no non-empty transcript in the selected text field(s)"

    row: dict[str, Any] = {
        "audio_filepath": relative_audio_path.as_posix(),
        "text": text,
        "language": str(record.get("language") or args.default_language).strip(),
        "quality_label": str(record.get("quality_label") or "unreviewed").strip(),
    }
    for field in ("id", "utterance_id", "raw_text", "speaker_id", "session_id", "device", "model"):
        value = record.get(field)
        if value not in (None, ""):
            # raw_text is evidence of the original ASR output, so preserve it
            # exactly rather than applying comparison-oriented normalization.
            row[field] = value
    try:
        metadata = inspect_wav(absolute_audio_path)
        row["duration"] = round(float(metadata["duration"]), 6)
    except (OSError, EOFError, ValueError, wave.Error) as error:
        return None, f"cannot inspect audio file: {error}"

    issues, _ = validate_record(
        row,
        line=1,
        dataset_root=dataset_root,
        require_duration=True,
        require_approved=args.approved_only,
        verify_audio=True,
        require_training_format=not args.allow_nontraining_audio,
    )
    errors = [issue.message for issue in issues if issue.level == "error"]
    if errors:
        return None, "; ".join(errors)
    return row, None


def main() -> int:
    args = parse_args()
    try:
        records = read_records(args.input_manifest)
        dataset_root = (args.dataset_root or args.input_manifest.parent).resolve()
        prepared: list[dict[str, Any]] = []
        rejected: list[dict[str, Any]] = []
        seen_audio: set[str] = set()
        for line, record in enumerate(records, start=1):
            row, reason = canonical_row(record, args, dataset_root)
            if row is None:
                rejected.append({"line": line, "reason": reason})
                continue
            if row["audio_filepath"] in seen_audio:
                rejected.append({"line": line, "reason": "duplicate audio_filepath"})
                continue
            seen_audio.add(row["audio_filepath"])
            prepared.append(row)
        report = {
            "input_manifest": str(args.input_manifest),
            "dataset_root": str(dataset_root),
            "output": str(args.output),
            "input_records": len(records),
            "prepared_records": len(prepared),
            "rejected_records": len(rejected),
            "rejections": rejected,
            "dry_run": args.dry_run,
        }
        if args.strict and rejected:
            print(json.dumps(report, ensure_ascii=False, indent=2), file=sys.stderr)
            print("error: --strict prevents writing a partial manifest", file=sys.stderr)
            return 1
        if not prepared:
            print(json.dumps(report, ensure_ascii=False, indent=2), file=sys.stderr)
            print("error: no usable records were prepared", file=sys.stderr)
            return 1
        if not args.dry_run:
            write_jsonl_atomic(args.output, prepared, overwrite=args.overwrite)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except (OSError, RecordFormatError, ValueError, FileExistsError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
