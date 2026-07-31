#!/usr/bin/env bash
# Download only an explicitly requested public test model. This is not a cloud
# ASR service and models remain outside source control by default.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
model="tiny"
output_dir="${project_root}/.local/models"
url=""
sha256=""
run=false
overwrite=false

usage() {
  cat <<'EOF'
Usage: Scripts/download_test_model.sh [options]

Prints a public GGML test-model download plan by default. Add --run to download
to a non-Git .local directory. This script never places model weights in Git.

Options:
  --model NAME       tiny, base, or small (default: tiny)
  --url URL          explicit alternate model URL
  --output-dir DIR   destination directory (default: .local/models)
  --sha256 HASH      optional expected SHA-256 checksum
  --run              perform the download
  --overwrite        replace an existing destination explicitly
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model|--url|--output-dir|--sha256)
      [[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --model) model="$2" ;;
        --url) url="$2" ;;
        --output-dir) output_dir="$2" ;;
        --sha256) sha256="$2" ;;
      esac
      shift 2
      ;;
    --run) run=true; shift ;;
    --overwrite) overwrite=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "${model}" in
  tiny|base|small) ;;
  *) echo "error: model must be tiny, base, or small" >&2; exit 2 ;;
esac
if [[ -z "${url}" ]]; then
  url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${model}.bin?download=true"
fi
destination="${output_dir}/ggml-${model}.bin"
if [[ -e "${destination}" && "${overwrite}" != true ]]; then
  echo "error: refusing to overwrite ${destination}; pass --overwrite explicitly" >&2
  exit 2
fi

echo "Model:       ${model}"
echo "Source URL:  ${url}"
echo "Destination: ${destination}"
if [[ -n "${sha256}" ]]; then echo "SHA-256:     ${sha256}"; fi
if [[ "${run}" != true ]]; then
  echo "Dry run only. Add --run after reviewing the model source and license."
  exit 0
fi

command -v curl >/dev/null || { echo "error: curl is required" >&2; exit 2; }
mkdir -p "${output_dir}"
temporary_path="${destination}.partial.$$"
trap 'rm -f "${temporary_path}"' EXIT
curl --fail --location --retry 3 --output "${temporary_path}" "${url}"
if [[ -n "${sha256}" ]]; then
  actual_sha256="$(shasum -a 256 "${temporary_path}" | awk '{print $1}')"
  [[ "${actual_sha256}" == "${sha256}" ]] || { echo "error: SHA-256 mismatch" >&2; exit 2; }
fi
mv -f "${temporary_path}" "${destination}"
trap - EXIT
echo "Downloaded model: ${destination}"
