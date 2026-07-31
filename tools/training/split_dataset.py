#!/usr/bin/env python3
"""Create deterministic train/validation/test manifests grouped by session.

Grouping is mandatory by default so adjacent utterances from a recording session
cannot leak from training into validation or test metrics.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import random
import sys
from typing import Any

TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

from evaluation.records import RecordFormatError, read_records, write_json_atomic, write_jsonl_atomic  # noqa: E402


SPLIT_NAMES = ("train", "validation", "test")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Split a manifest by session, never by individual utterance.")
    parser.add_argument("--manifest", type=Path, required=True, help="Canonical input manifest.")
    parser.add_argument("--output-dir", type=Path, required=True, help="Directory for train/validation/test JSONL files.")
    parser.add_argument("--group-field", default="session_id", help="Field that defines a leakage-safe group (default: session_id).")
    parser.add_argument("--train-ratio", type=float, default=0.8)
    parser.add_argument("--validation-ratio", type=float, default=0.1)
    parser.add_argument("--test-ratio", type=float, default=0.1)
    parser.add_argument("--seed", type=int, default=2026, help="Stored deterministic split seed (default: 2026).")
    parser.add_argument(
        "--approved-only",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Split only quality_label=approved rows (default: true).",
    )
    parser.add_argument("--dry-run", action="store_true", help="Report the split without creating files.")
    parser.add_argument("--overwrite", action="store_true", help="Allow atomically replacing existing split files.")
    return parser.parse_args()


def ratios_from_args(args: argparse.Namespace) -> dict[str, float]:
    ratios = {
        "train": args.train_ratio,
        "validation": args.validation_ratio,
        "test": args.test_ratio,
    }
    if any(value < 0 for value in ratios.values()) or sum(ratios.values()) <= 0:
        raise ValueError("split ratios must be non-negative and have a positive total")
    total = sum(ratios.values())
    return {name: value / total for name, value in ratios.items()}


def group_records(records: list[dict[str, Any]], field: str, approved_only: bool) -> dict[str, list[dict[str, Any]]]:
    groups: dict[str, list[dict[str, Any]]] = {}
    for line, record in enumerate(records, start=1):
        if approved_only and record.get("quality_label") != "approved":
            continue
        group = str(record.get(field, "")).strip()
        if not group:
            raise ValueError(f"row {line} has no '{field}'; refusing an utterance-level split that could leak data")
        groups.setdefault(group, []).append(record)
    if not groups:
        raise ValueError("no records remain after filtering")
    return groups


def choose_split(
    group_count: int, counts: dict[str, int], targets: dict[str, float], active_splits: list[str]
) -> str:
    def score(name: str) -> tuple[float, float, str]:
        projected = counts[name] + group_count
        # Normalise by the intended split size so train's large target does not
        # automatically absorb every early group.
        normalizer = max(targets[name], 1.0)
        return (abs(projected - targets[name]) / normalizer, -(targets[name] - counts[name]), name)

    return min(active_splits, key=score)


def enforce_nonempty_splits(
    assignments: dict[str, str], groups: dict[str, list[dict[str, Any]]], ratios: dict[str, float]
) -> None:
    active_splits = [name for name in SPLIT_NAMES if ratios[name] > 0]
    if len(groups) < len(active_splits):
        raise ValueError(f"need at least {len(active_splits)} distinct groups for non-empty requested splits")
    group_counts = {name: 0 for name in active_splits}
    session_counts = {name: 0 for name in active_splits}
    for session, split in assignments.items():
        group_counts[split] += len(groups[session])
        session_counts[split] += 1
    total = sum(group_counts.values())
    targets = {name: total * ratios[name] for name in active_splits}
    for empty_split in [name for name in active_splits if session_counts[name] == 0]:
        candidates = [
            session
            for session, split in assignments.items()
            if session_counts[split] > 1
        ]
        if not candidates:
            raise ValueError("cannot make every requested split non-empty while preserving group isolation")

        def movement_cost(session: str) -> tuple[float, str]:
            current_split = assignments[session]
            moved_counts = dict(group_counts)
            moved_counts[current_split] -= len(groups[session])
            moved_counts[empty_split] += len(groups[session])
            cost = sum((moved_counts[name] - targets[name]) ** 2 for name in active_splits)
            return cost, session

        selected = min(candidates, key=movement_cost)
        old_split = assignments[selected]
        assignments[selected] = empty_split
        session_counts[old_split] -= 1
        session_counts[empty_split] += 1
        group_counts[old_split] -= len(groups[selected])
        group_counts[empty_split] += len(groups[selected])


def make_assignments(groups: dict[str, list[dict[str, Any]]], ratios: dict[str, float], seed: int) -> dict[str, str]:
    active_splits = [name for name in SPLIT_NAMES if ratios[name] > 0]
    randomizer = random.Random(seed)
    ordered_sessions = list(groups)
    randomizer.shuffle(ordered_sessions)
    ordered_sessions.sort(key=lambda session: len(groups[session]), reverse=True)
    total = sum(len(rows) for rows in groups.values())
    targets = {name: total * ratios[name] for name in active_splits}
    counts = {name: 0 for name in active_splits}
    assignments: dict[str, str] = {}
    for session in ordered_sessions:
        split = choose_split(len(groups[session]), counts, targets, active_splits)
        assignments[session] = split
        counts[split] += len(groups[session])
    enforce_nonempty_splits(assignments, groups, ratios)
    return assignments


def split_summary(rows_by_split: dict[str, list[dict[str, Any]]], group_field: str) -> dict[str, dict[str, int | float]]:
    summary: dict[str, dict[str, int | float]] = {}
    for split, rows in rows_by_split.items():
        durations = [float(row.get("duration", 0) or 0) for row in rows]
        summary[split] = {
            "records": len(rows),
            "groups": len({str(row[group_field]) for row in rows}),
            "duration_seconds": round(sum(durations), 3),
        }
    return summary


def main() -> int:
    args = parse_args()
    try:
        ratios = ratios_from_args(args)
        records = read_records(args.manifest)
        groups = group_records(records, args.group_field, args.approved_only)
        assignments = make_assignments(groups, ratios, args.seed)
        rows_by_split = {name: [] for name in SPLIT_NAMES}
        for record in records:
            if args.approved_only and record.get("quality_label") != "approved":
                continue
            group = str(record.get(args.group_field, "")).strip()
            if group in assignments:
                rows_by_split[assignments[group]].append(record)
        groups_by_split = {
            name: {str(record[args.group_field]) for record in rows}
            for name, rows in rows_by_split.items()
        }
        if any(groups_by_split[first] & groups_by_split[second] for first in SPLIT_NAMES for second in SPLIT_NAMES if first < second):
            raise RuntimeError("internal error: a group was assigned to multiple splits")
        summary = split_summary(rows_by_split, args.group_field)
        metadata = {
            "input_manifest": str(args.manifest),
            "group_field": args.group_field,
            "seed": args.seed,
            "ratios": ratios,
            "approved_only": args.approved_only,
            "summary": summary,
            "session_overlap_verified": True,
        }
        if not args.dry_run:
            output_paths = {
                name: args.output_dir / f"{name}.jsonl" for name in SPLIT_NAMES if ratios[name] > 0
            }
            output_paths["metadata"] = args.output_dir / "split_metadata.json"
            existing = [path for path in output_paths.values() if path.exists()]
            if existing and not args.overwrite:
                raise FileExistsError("Refusing to overwrite: " + ", ".join(str(path) for path in existing))
            for name, path in output_paths.items():
                if name == "metadata":
                    write_json_atomic(path, metadata, overwrite=args.overwrite)
                else:
                    write_jsonl_atomic(path, rows_by_split[name], overwrite=args.overwrite)
        print(json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    except (OSError, RecordFormatError, RuntimeError, ValueError, FileExistsError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
