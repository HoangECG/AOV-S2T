#!/usr/bin/env python3
"""Safely invoke a user-supplied whisper.cpp-compatible model converter.

Fine-tuned Hugging Face checkpoints are not automatically compatible with every
whisper.cpp revision.  This wrapper verifies the checkpoint looks like Whisper,
prints the exact no-shell command first, and runs only with --run.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys
from typing import Any


DEFAULT_TEMPLATE = "{python} {converter} {input} --outfile {output}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a verified local conversion command for a Whisper checkpoint.")
    parser.add_argument("--input-dir", type=Path, required=True, help="Fine-tuned, merged Hugging Face Whisper directory.")
    parser.add_argument("--output", type=Path, required=True, help="New converted model output path.")
    parser.add_argument("--converter", type=Path, required=True, help="Converter script/binary for the pinned local whisper.cpp revision.")
    parser.add_argument(
        "--command-template",
        default=DEFAULT_TEMPLATE,
        help="Token-safe command template; allowed placeholders: {python}, {converter}, {input}, {output}.",
    )
    parser.add_argument("--converter-arg", action="append", default=[], help="Additional argument passed after the rendered command.")
    parser.add_argument("--quantizer", type=Path, help="Optional local quantizer binary; no default is assumed.")
    parser.add_argument("--quantized-output", type=Path, help="Required with --quantizer; new quantized output path.")
    parser.add_argument("--quantization", help="Quantizer type passed as its final argument, e.g. Q5_K_M.")
    parser.add_argument("--run", action="store_true", help="Actually execute conversion. Otherwise print a dry-run plan.")
    parser.add_argument("--overwrite", action="store_true", help="Allow a converter or quantizer to replace an existing output explicitly.")
    return parser.parse_args()


def load_whisper_config(input_dir: Path) -> dict[str, Any]:
    config_path = input_dir / "config.json"
    if not config_path.is_file():
        raise ValueError("input-dir has no config.json; merge LoRA adapters into a full Whisper checkpoint first")
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid config.json: {error.msg}") from error
    if config.get("model_type") != "whisper":
        raise ValueError(f"model_type must be 'whisper', got {config.get('model_type')!r}")
    return config


def render_command(template: str, *, converter: Path, input_dir: Path, output: Path, extra: list[str]) -> list[str]:
    values = {
        "python": shlex.quote(sys.executable),
        "converter": shlex.quote(str(converter)),
        "input": shlex.quote(str(input_dir)),
        "output": shlex.quote(str(output)),
    }
    try:
        command = shlex.split(template.format(**values))
    except (KeyError, ValueError) as error:
        raise ValueError(f"invalid --command-template: {error}") from error
    if not command:
        raise ValueError("--command-template produced an empty command")
    return [*command, *extra]


def command_text(command: list[str]) -> str:
    return shlex.join(command)


def validate_paths(args: argparse.Namespace) -> dict[str, Any]:
    input_dir = args.input_dir.resolve()
    converter = args.converter.resolve()
    if not input_dir.is_dir():
        raise ValueError(f"input-dir does not exist: {input_dir}")
    if not converter.is_file():
        raise ValueError(f"converter does not exist: {converter}")
    config = load_whisper_config(input_dir)
    if args.output.exists() and not args.overwrite:
        raise FileExistsError(f"Refusing to overwrite {args.output}; pass --overwrite explicitly")
    if args.quantizer or args.quantized_output or args.quantization:
        if not (args.quantizer and args.quantized_output and args.quantization):
            raise ValueError("--quantizer, --quantized-output, and --quantization must be supplied together")
        if not args.quantizer.is_file():
            raise ValueError(f"quantizer does not exist: {args.quantizer}")
        if args.quantized_output.exists() and not args.overwrite:
            raise FileExistsError(f"Refusing to overwrite {args.quantized_output}; pass --overwrite explicitly")
    return {"input_dir": input_dir, "converter": converter, "config": config}


def main() -> int:
    args = parse_args()
    try:
        values = validate_paths(args)
        output = args.output.resolve()
        command = render_command(
            args.command_template,
            converter=values["converter"],
            input_dir=values["input_dir"],
            output=output,
            extra=args.converter_arg,
        )
        report: dict[str, Any] = {
            "input_model_type": values["config"].get("model_type"),
            "converter": str(values["converter"]),
            "conversion_command": command_text(command),
            "run": args.run,
            "conversion_output": str(output),
        }
        if args.quantizer:
            quantized_output = args.quantized_output.resolve()
            quantizer_command = [str(args.quantizer.resolve()), str(output), str(quantized_output), args.quantization]
            report["quantization_command"] = command_text(quantizer_command)
            report["quantized_output"] = str(quantized_output)
        if not args.run:
            print(json.dumps(report, ensure_ascii=False, indent=2))
            return 0

        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(command, check=True)
        if not output.is_file() or output.stat().st_size == 0:
            raise RuntimeError("converter exited successfully but did not create a non-empty output file")
        report["conversion_output_bytes"] = output.stat().st_size
        if args.quantizer:
            quantized_output.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(quantizer_command, check=True)
            if not quantized_output.is_file() or quantized_output.stat().st_size == 0:
                raise RuntimeError("quantizer exited successfully but did not create a non-empty output file")
            report["quantized_output_bytes"] = quantized_output.stat().st_size
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, FileExistsError, subprocess.CalledProcessError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
