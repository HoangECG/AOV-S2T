#!/usr/bin/env python3
"""Evaluate transcript pairs without sending text or audio to a service.

Examples:
  python3 tools/evaluation/evaluate_transcripts.py \
    --reference heldout.jsonl --hypothesis predictions.jsonl --key utterance_id
  python3 tools/evaluation/evaluate_transcripts.py \
    --reference reference.csv --hypothesis output.csv --entities glossary.txt
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

TOOL_ROOT = Path(__file__).resolve().parents[1]
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

from evaluation.metrics import (  # noqa: E402
    PrecisionRecallF1,
    corpus_error_rate,
    count_entity_occurrences,
    extract_numbers,
    occurrence_prf,
    sentence_boundary_prf,
)
from evaluation.records import RecordFormatError, read_records, write_json_atomic  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Calculate offline WER, CER, and transcript-quality metrics.")
    parser.add_argument("--reference", type=Path, required=True, help="JSONL/JSON/CSV/TSV records containing reference text.")
    parser.add_argument("--hypothesis", type=Path, required=True, help="JSONL/JSON/CSV/TSV records containing ASR output.")
    parser.add_argument("--key", default="id", help="Field used to align rows (default: id).")
    parser.add_argument("--reference-field", default="text", help="Reference transcript field (default: text).")
    parser.add_argument("--hypothesis-field", default="text", help="Hypothesis transcript field (default: text).")
    parser.add_argument("--entities", type=Path, help="Optional .txt or record file of canonical named entities.")
    parser.add_argument("--allow-unmatched", action="store_true", help="Score only shared keys instead of failing on missing rows.")
    parser.add_argument("--per-record", action="store_true", help="Include WER/CER for every matched record in JSON output.")
    parser.add_argument("--output", type=Path, help="Write the JSON report atomically instead of stdout only.")
    parser.add_argument("--overwrite", action="store_true", help="Allow replacing an existing --output file.")
    return parser.parse_args()


def keyed_records(records: list[dict[str, Any]], key: str, source: Path) -> dict[str, dict[str, Any]]:
    indexed: dict[str, dict[str, Any]] = {}
    for row_number, record in enumerate(records, start=1):
        value = str(record.get(key, "")).strip()
        if not value:
            raise ValueError(f"{source}: row {row_number} has no non-empty '{key}' value")
        if value in indexed:
            raise ValueError(f"{source}: duplicate '{key}' value '{value}'")
        indexed[value] = record
    return indexed


def load_entities(path: Path | None) -> list[str]:
    if path is None:
        return []
    if path.suffix.casefold() == ".txt":
        values = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()]
    else:
        values = []
        for record in read_records(path):
            value = record.get("canonical_text", record.get("entity", record.get("text", "")))
            values.append(str(value).strip())
    return list(dict.fromkeys(value for value in values if value))


def aggregate_prf(values: list[PrecisionRecallF1]) -> PrecisionRecallF1:
    return PrecisionRecallF1(
        sum(value.true_positive for value in values),
        sum(value.false_positive for value in values),
        sum(value.false_negative for value in values),
    )


def entity_occurrences(text: object, entities: list[str]) -> list[str]:
    return [entity for entity in entities for _ in range(count_entity_occurrences(text, entity))]


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    references = keyed_records(read_records(args.reference), args.key, args.reference)
    hypotheses = keyed_records(read_records(args.hypothesis), args.key, args.hypothesis)
    reference_keys = set(references)
    hypothesis_keys = set(hypotheses)
    missing_hypotheses = sorted(reference_keys - hypothesis_keys)
    unexpected_hypotheses = sorted(hypothesis_keys - reference_keys)
    if (missing_hypotheses or unexpected_hypotheses) and not args.allow_unmatched:
        raise ValueError(
            "Input keys differ. Refusing to silently score a partial comparison; "
            "use --allow-unmatched to score only the intersection. "
            f"Missing hypotheses: {len(missing_hypotheses)}; unexpected hypotheses: {len(unexpected_hypotheses)}."
        )

    keys = sorted(reference_keys & hypothesis_keys)
    if not keys:
        raise ValueError("No matched records to evaluate")
    pairs = [(references[key].get(args.reference_field, ""), hypotheses[key].get(args.hypothesis_field, "")) for key in keys]
    if any(not isinstance(reference, str) or not isinstance(hypothesis, str) for reference, hypothesis in pairs):
        raise ValueError("Transcript fields must contain strings")

    entities = load_entities(args.entities)
    sentence_scores = [sentence_boundary_prf(reference, hypothesis) for reference, hypothesis in pairs]
    report: dict[str, Any] = {
        "inputs": {
            "reference": str(args.reference),
            "hypothesis": str(args.hypothesis),
            "key": args.key,
            "reference_field": args.reference_field,
            "hypothesis_field": args.hypothesis_field,
        },
        "records": {
            "reference": len(references),
            "hypothesis": len(hypotheses),
            "matched": len(keys),
            "missing_hypotheses": len(missing_hypotheses),
            "unexpected_hypotheses": len(unexpected_hypotheses),
        },
        "wer": corpus_error_rate((pair[0] for pair in pairs), (pair[1] for pair in pairs), unit="word").as_dict(),
        "cer": corpus_error_rate((pair[0] for pair in pairs), (pair[1] for pair in pairs), unit="character").as_dict(),
        "number_accuracy": occurrence_prf(
            (extract_numbers(pair[0]) for pair in pairs), (extract_numbers(pair[1]) for pair in pairs)
        ).as_dict(),
        "sentence_boundary": aggregate_prf(sentence_scores).as_dict(),
    }
    if entities:
        report["named_entity_accuracy"] = occurrence_prf(
            (entity_occurrences(pair[0], entities) for pair in pairs),
            (entity_occurrences(pair[1], entities) for pair in pairs),
        ).as_dict()
        report["named_entity_accuracy"]["entity_vocabulary_size"] = len(entities)
    else:
        report["named_entity_accuracy"] = None

    if args.per_record:
        report["per_record"] = [
            {
                args.key: key,
                "wer": corpus_error_rate([reference], [hypothesis], unit="word").as_dict(),
                "cer": corpus_error_rate([reference], [hypothesis], unit="character").as_dict(),
                "sentence_boundary": sentence_boundary_prf(reference, hypothesis).as_dict(),
            }
            for key, (reference, hypothesis) in zip(keys, pairs, strict=True)
        ]
    return report


def main() -> int:
    args = parse_args()
    try:
        report = build_report(args)
        if args.output:
            write_json_atomic(args.output, report, overwrite=args.overwrite)
        import json

        print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    except (OSError, RecordFormatError, ValueError, FileExistsError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
