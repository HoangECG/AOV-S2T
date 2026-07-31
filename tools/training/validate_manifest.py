#!/usr/bin/env python3
"""Validate a privacy-safe 16 kHz mono WAV training manifest locally."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

from evaluation.records import RecordFormatError, read_records, write_json_atomic  # noqa: E402
from manifest_utils import ManifestIssue, validate_record  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check a JSONL/CSV manifest before splitting or fine-tuning.")
    parser.add_argument("--manifest", type=Path, required=True, help="Manifest to inspect (.jsonl, .json, .csv, or .tsv).")
    parser.add_argument(
        "--dataset-root",
        type=Path,
        help="Root to which audio_filepath values are relative (default: manifest parent directory).",
    )
    parser.add_argument("--require-approved", action="store_true", help="Reject rows whose quality_label is not approved.")
    parser.add_argument("--allow-missing-duration", action="store_true", help="Do not require a positive duration field.")
    parser.add_argument("--no-verify-audio", action="store_true", help="Validate row schema only; do not open audio files.")
    parser.add_argument(
        "--allow-nontraining-audio",
        action="store_true",
        help="Permit WAVs that are not 16 kHz, mono, 16-bit PCM (useful before conversion).",
    )
    parser.add_argument("--report", type=Path, help="Optional JSON report path.")
    parser.add_argument("--overwrite", action="store_true", help="Allow replacing an existing --report file.")
    parser.add_argument("--max-printed-issues", type=int, default=100, help="Limit issue lines printed to stderr.")
    return parser.parse_args()


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    records = read_records(args.manifest)
    dataset_root = (args.dataset_root or args.manifest.parent).resolve()
    issues: list[ManifestIssue] = []
    seen_audio: dict[str, int] = {}
    seen_ids: dict[str, int] = {}
    for line, record in enumerate(records, start=1):
        row_issues, _ = validate_record(
            record,
            line=line,
            dataset_root=dataset_root,
            require_duration=not args.allow_missing_duration,
            require_approved=args.require_approved,
            verify_audio=not args.no_verify_audio,
            require_training_format=not args.allow_nontraining_audio,
        )
        issues.extend(row_issues)
        audio_path = str(record.get("audio_filepath", "")).strip()
        if audio_path:
            previous = seen_audio.setdefault(audio_path, line)
            if previous != line:
                issues.append(ManifestIssue(line, "error", "duplicate_audio", f"duplicates row {previous}: {audio_path}"))
        identifier = str(record.get("id", record.get("utterance_id", ""))).strip()
        if identifier:
            previous = seen_ids.setdefault(identifier, line)
            if previous != line:
                issues.append(ManifestIssue(line, "error", "duplicate_id", f"duplicates row {previous}: {identifier}"))
        if not str(record.get("language", "")).strip():
            issues.append(ManifestIssue(line, "warning", "language", "language is absent; expected 'vi' for this project"))

    errors = [issue for issue in issues if issue.level == "error"]
    warnings = [issue for issue in issues if issue.level == "warning"]
    return {
        "manifest": str(args.manifest),
        "dataset_root": str(dataset_root),
        "records": len(records),
        "errors": len(errors),
        "warnings": len(warnings),
        "valid": not errors,
        "issues": [issue.as_dict() for issue in issues],
    }


def main() -> int:
    args = parse_args()
    try:
        report = build_report(args)
        for issue in report["issues"][: args.max_printed_issues]:
            print(f"{issue['level']}: row {issue['line']} [{issue['code']}] {issue['message']}", file=sys.stderr)
        hidden_issue_count = len(report["issues"]) - args.max_printed_issues
        if hidden_issue_count > 0:
            print(f"… {hidden_issue_count} more issue(s) omitted", file=sys.stderr)
        if args.report:
            write_json_atomic(args.report, report, overwrite=args.overwrite)
        print(json.dumps({key: value for key, value in report.items() if key != "issues"}, ensure_ascii=False))
        return 0 if report["valid"] else 1
    except (OSError, RecordFormatError, ValueError, FileExistsError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
