#!/usr/bin/env python3
"""Small, dependency-free metrics used by the offline evaluation tools.

The normalisation in this module intentionally preserves Vietnamese Unicode.  It
only makes comparisons less sensitive to whitespace and case; it never tries to
rewrite spoken numbers or apply glossary substitutions.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from difflib import SequenceMatcher
import re
import unicodedata
from typing import Iterable, Sequence


_WHITESPACE = re.compile(r"\s+", re.UNICODE)
_WORD = re.compile(r"\d+(?:[.,]\d+)?%?|[^\W_]+(?:['’][^\W_]+)?", re.UNICODE)
_SENTENCE_END = re.compile(r"[.!?…]+", re.UNICODE)


def canonical_text(value: object) -> str:
    """Return a comparison-safe form without dropping Vietnamese diacritics."""
    return _WHITESPACE.sub(" ", unicodedata.normalize("NFC", str(value or "")).strip())


def word_tokens(value: object) -> list[str]:
    return [match.group(0).casefold() for match in _WORD.finditer(canonical_text(value))]


def character_tokens(value: object) -> list[str]:
    return list(canonical_text(value).casefold())


def edit_distance(reference: Sequence[str], hypothesis: Sequence[str]) -> int:
    """Levenshtein distance with O(min(n, m)) memory."""
    if len(reference) < len(hypothesis):
        reference, hypothesis = hypothesis, reference
    previous = list(range(len(hypothesis) + 1))
    for reference_index, reference_token in enumerate(reference, start=1):
        current = [reference_index]
        for hypothesis_index, hypothesis_token in enumerate(hypothesis, start=1):
            substitution = previous[hypothesis_index - 1] + (reference_token != hypothesis_token)
            insertion = current[hypothesis_index - 1] + 1
            deletion = previous[hypothesis_index] + 1
            current.append(min(substitution, insertion, deletion))
        previous = current
    return previous[-1]


@dataclass(frozen=True)
class ErrorRate:
    distance: int
    reference_units: int

    @property
    def value(self) -> float:
        return self.distance / self.reference_units if self.reference_units else 0.0

    def as_dict(self) -> dict[str, float | int]:
        return {
            "distance": self.distance,
            "reference_units": self.reference_units,
            "rate": self.value,
        }


def corpus_error_rate(
    references: Iterable[object], hypotheses: Iterable[object], *, unit: str
) -> ErrorRate:
    tokenizer = word_tokens if unit == "word" else character_tokens
    distance = 0
    reference_units = 0
    for reference, hypothesis in zip(references, hypotheses, strict=True):
        reference_tokens = tokenizer(reference)
        hypothesis_tokens = tokenizer(hypothesis)
        distance += edit_distance(reference_tokens, hypothesis_tokens)
        reference_units += len(reference_tokens)
    return ErrorRate(distance=distance, reference_units=reference_units)


def extract_numbers(value: object) -> list[str]:
    """Extract digit-based numbers, normalising a decimal comma to a decimal point."""
    values: list[str] = []
    for token in word_tokens(value):
        if re.fullmatch(r"\d+(?:[.,]\d+)?%?", token):
            values.append(token.replace(",", "."))
    return values


def count_entity_occurrences(value: object, entity: object) -> int:
    """Count whole-token occurrences of one supplied canonical entity."""
    phrase = word_tokens(entity)
    tokens = word_tokens(value)
    if not phrase or len(phrase) > len(tokens):
        return 0
    width = len(phrase)
    return sum(tokens[index : index + width] == phrase for index in range(len(tokens) - width + 1))


@dataclass(frozen=True)
class PrecisionRecallF1:
    true_positive: int
    false_positive: int
    false_negative: int

    @property
    def precision(self) -> float:
        denominator = self.true_positive + self.false_positive
        return self.true_positive / denominator if denominator else 1.0

    @property
    def recall(self) -> float:
        denominator = self.true_positive + self.false_negative
        return self.true_positive / denominator if denominator else 1.0

    @property
    def f1(self) -> float:
        denominator = self.precision + self.recall
        return 2 * self.precision * self.recall / denominator if denominator else 0.0

    def as_dict(self) -> dict[str, float | int]:
        return {
            "true_positive": self.true_positive,
            "false_positive": self.false_positive,
            "false_negative": self.false_negative,
            "precision": self.precision,
            "recall": self.recall,
            "f1": self.f1,
        }


def occurrence_prf(
    reference_values: Iterable[Iterable[str]], hypothesis_values: Iterable[Iterable[str]]
) -> PrecisionRecallF1:
    true_positive = false_positive = false_negative = 0
    for reference, hypothesis in zip(reference_values, hypothesis_values, strict=True):
        reference_counts = Counter(reference)
        hypothesis_counts = Counter(hypothesis)
        true_positive += sum((reference_counts & hypothesis_counts).values())
        false_negative += sum((reference_counts - hypothesis_counts).values())
        false_positive += sum((hypothesis_counts - reference_counts).values())
    return PrecisionRecallF1(true_positive, false_positive, false_negative)


def sentence_boundaries(value: object) -> tuple[list[str], set[int]]:
    """Return word tokens and punctuation-derived sentence ends (1-based positions)."""
    text = canonical_text(value)
    tokens: list[str] = []
    boundaries: set[int] = set()
    cursor = 0
    for match in _SENTENCE_END.finditer(text):
        tokens.extend(word_tokens(text[cursor : match.start()]))
        if tokens:
            boundaries.add(len(tokens))
        cursor = match.end()
    tokens.extend(word_tokens(text[cursor:]))
    return tokens, boundaries


def sentence_boundary_prf(reference: object, hypothesis: object) -> PrecisionRecallF1:
    """Score punctuation boundaries after mapping equal token runs between texts.

    This is intentionally a conservative metric: a boundary only matches when
    the token immediately preceding it aligns exactly in both transcripts.
    """
    reference_tokens, reference_boundaries = sentence_boundaries(reference)
    hypothesis_tokens, hypothesis_boundaries = sentence_boundaries(hypothesis)
    reference_to_hypothesis: dict[int, int] = {}
    matcher = SequenceMatcher(a=reference_tokens, b=hypothesis_tokens, autojunk=False)
    for block in matcher.get_matching_blocks():
        for offset in range(block.size):
            reference_to_hypothesis[block.a + offset] = block.b + offset

    matched_hypothesis: set[int] = set()
    true_positive = false_negative = 0
    for boundary in reference_boundaries:
        mapped_final_token = reference_to_hypothesis.get(boundary - 1)
        mapped_boundary = mapped_final_token + 1 if mapped_final_token is not None else None
        if mapped_boundary in hypothesis_boundaries:
            true_positive += 1
            matched_hypothesis.add(mapped_boundary)
        else:
            false_negative += 1
    false_positive = len(hypothesis_boundaries - matched_hypothesis)
    return PrecisionRecallF1(true_positive, false_positive, false_negative)
