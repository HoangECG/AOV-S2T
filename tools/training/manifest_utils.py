#!/usr/bin/env python3
"""Validation primitives shared by the local training scripts."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import math
import wave
from typing import Any


@dataclass(frozen=True)
class ManifestIssue:
    line: int
    level: str
    code: str
    message: str

    def as_dict(self) -> dict[str, str | int]:
        return {"line": self.line, "level": self.level, "code": self.code, "message": self.message}


def safe_relative_audio_path(value: object) -> Path:
    value_as_text = str(value or "").strip()
    if not value_as_text:
        raise ValueError("audio_filepath is required")
    path = Path(value_as_text)
    if path.is_absolute() or ".." in path.parts or path == Path("."):
        raise ValueError("audio_filepath must be a non-empty relative path without '..'")
    return path


def resolve_audio_path(dataset_root: Path, value: object) -> tuple[Path, Path]:
    relative_path = safe_relative_audio_path(value)
    root = dataset_root.resolve()
    absolute_path = (root / relative_path).resolve()
    try:
        absolute_path.relative_to(root)
    except ValueError as error:
        raise ValueError("audio_filepath resolves outside dataset root") from error
    return relative_path, absolute_path


def inspect_wav(path: Path) -> dict[str, float | int | str]:
    """Inspect standard WAV metadata with Python's built-in wave reader."""
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        sample_rate = wav.getframerate()
        sample_width = wav.getsampwidth()
        frame_count = wav.getnframes()
        compression = wav.getcomptype()
    duration = frame_count / sample_rate if sample_rate else 0.0
    return {
        "channels": channels,
        "sample_rate": sample_rate,
        "sample_width_bytes": sample_width,
        "frame_count": frame_count,
        "duration": duration,
        "compression": compression,
    }


def positive_duration(value: object) -> float:
    try:
        duration = float(value)
    except (TypeError, ValueError) as error:
        raise ValueError("duration must be a positive number") from error
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("duration must be a positive finite number")
    return duration


def validate_record(
    record: dict[str, Any],
    *,
    line: int,
    dataset_root: Path,
    require_duration: bool,
    require_approved: bool,
    verify_audio: bool,
    require_training_format: bool,
) -> tuple[list[ManifestIssue], dict[str, float | int | str] | None]:
    """Validate one canonical manifest record without modifying it."""
    issues: list[ManifestIssue] = []
    wav_metadata: dict[str, float | int | str] | None = None
    text = record.get("text")
    if not isinstance(text, str) or not text.strip():
        issues.append(ManifestIssue(line, "error", "text", "text must be a non-empty string"))
    if require_approved and record.get("quality_label") != "approved":
        issues.append(ManifestIssue(line, "error", "quality_label", "quality_label must be 'approved'"))

    duration: float | None = None
    if "duration" in record and record.get("duration") not in (None, ""):
        try:
            duration = positive_duration(record["duration"])
        except ValueError as error:
            issues.append(ManifestIssue(line, "error", "duration", str(error)))
    elif require_duration:
        issues.append(ManifestIssue(line, "error", "duration", "duration is required"))

    try:
        relative_path, audio_path = resolve_audio_path(dataset_root, record.get("audio_filepath"))
    except ValueError as error:
        issues.append(ManifestIssue(line, "error", "audio_filepath", str(error)))
        return issues, None
    if relative_path.suffix.casefold() != ".wav":
        issues.append(ManifestIssue(line, "error", "audio_format", "audio_filepath must point to a .wav file"))
    if not verify_audio:
        return issues, None
    if not audio_path.is_file():
        issues.append(ManifestIssue(line, "error", "audio_missing", f"audio file does not exist: {relative_path}"))
        return issues, None
    try:
        wav_metadata = inspect_wav(audio_path)
    except (OSError, EOFError, wave.Error) as error:
        issues.append(ManifestIssue(line, "error", "wav_read", f"cannot read WAV metadata: {error}"))
        return issues, None
    if wav_metadata["compression"] != "NONE":
        issues.append(ManifestIssue(line, "error", "wav_compression", "WAV must use uncompressed PCM"))
    if require_training_format:
        if wav_metadata["sample_rate"] != 16_000:
            issues.append(ManifestIssue(line, "error", "sample_rate", "WAV must be 16 kHz"))
        if wav_metadata["channels"] != 1:
            issues.append(ManifestIssue(line, "error", "channels", "WAV must be mono"))
        if wav_metadata["sample_width_bytes"] != 2:
            issues.append(ManifestIssue(line, "error", "sample_width", "WAV must be 16-bit PCM"))
    if duration is not None and abs(duration - float(wav_metadata["duration"])) > 0.05:
        issues.append(
            ManifestIssue(
                line,
                "warning",
                "duration_mismatch",
                f"manifest duration {duration:.3f}s differs from WAV duration {float(wav_metadata['duration']):.3f}s",
            )
        )
    return issues, wav_metadata
