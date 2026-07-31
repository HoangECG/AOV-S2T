#!/usr/bin/env bash
# Reproducible package and offline-tool checks. Hardware, model, and permission
# tests remain manual because they cannot run reliably in CI.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
run_swift=true
run_tools=true
verbose=false

usage() {
  cat <<'EOF'
Usage: Scripts/run_tests.sh [--swift-only|--tools-only] [--verbose]

Runs the dependency-free Swift core-check executable and Python syntax/help
checks for offline dataset tooling. It does not require a microphone, Screen
Recording permission, model weights, network access, XCTest, or Testing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --swift-only) run_tools=false ;;
    --tools-only) run_swift=false ;;
    --verbose) verbose=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "${run_swift}" == true ]]; then
  command -v swift >/dev/null || { echo "error: Swift is not installed or not on PATH" >&2; exit 2; }
  swift_args=(run MacSpeechTranslatorCoreChecks)
  if [[ "${verbose}" == true ]]; then swift_args+=(--verbose); fi
  (cd "${project_root}" && swift "${swift_args[@]}")
fi

if [[ "${run_tools}" == true ]]; then
  command -v python3 >/dev/null || { echo "error: python3 is required for tooling checks" >&2; exit 2; }
  cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/macspeechtranslator-pyc.XXXXXX")"
  trap 'rm -rf "${cache_dir}"' EXIT
  export PYTHONPYCACHEPREFIX="${cache_dir}"
  python3 -m compileall -q "${project_root}/tools"
  for script in \
    "${project_root}/tools/training/prepare_dataset.py" \
    "${project_root}/tools/training/validate_manifest.py" \
    "${project_root}/tools/training/split_dataset.py" \
    "${project_root}/tools/training/evaluate_asr.py" \
    "${project_root}/tools/training/finetune_whisper.py" \
    "${project_root}/tools/training/export_model.py" \
    "${project_root}/tools/evaluation/evaluate_transcripts.py"; do
    python3 "${script}" --help >/dev/null
  done
  rm -rf "${cache_dir}"
  trap - EXIT
  echo "Offline tooling syntax and CLI checks passed."
fi
