#!/usr/bin/env bash
# Inspect the local Swift package environment. Dependency resolution is opt-in
# because it may access the network and update local build state.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
resolve=false
fetch_whisper=false

usage() {
  cat <<'EOF'
Usage: Scripts/bootstrap.sh [--resolve] [--fetch-whisper]

Checks the local Swift and Xcode toolchain for this Swift Package. --resolve
explicitly runs `swift package resolve`; it may access the network.
--fetch-whisper explicitly clones the pinned whisper.cpp v1.8.3 source into
Vendor/whisper.cpp; it never downloads model weights.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resolve) resolve=true ;;
    --fetch-whisper) fetch_whisper=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f "${project_root}/Package.swift" ]]; then
  echo "error: Package.swift was not found at ${project_root}" >&2
  exit 2
fi

command -v swift >/dev/null || { echo "error: Swift is not installed or not on PATH" >&2; exit 2; }

echo "Project: ${project_root}"
swift --version
if command -v xcodebuild >/dev/null; then
  if ! xcodebuild -version; then
    echo "Note: xcodebuild is present but a full Xcode developer directory is not selected."
  fi
else
  echo "Note: xcodebuild is unavailable; Swift Package commands can still be inspected."
fi

if [[ "${resolve}" == true ]]; then
  (cd "${project_root}" && swift package resolve)
else
  (cd "${project_root}" && swift package describe --type json >/dev/null)
  echo "Package manifest parsed. Run with --resolve to resolve dependencies explicitly."
fi

if [[ "${fetch_whisper}" == true ]]; then
  command -v git >/dev/null || { echo "error: git is required to fetch whisper.cpp" >&2; exit 2; }
  vendor_dir="${project_root}/Vendor/whisper.cpp"
  revision_file="${vendor_dir}/REVISION"
  expected_revision="$(tr -d '[:space:]' < "${revision_file}")"
  if [[ -d "${vendor_dir}/.git" ]]; then
    actual_revision="$(git -C "${vendor_dir}" rev-parse HEAD)"
    [[ "${actual_revision}" == "${expected_revision}" ]] || {
      echo "error: existing Vendor/whisper.cpp is not pinned at ${expected_revision}" >&2
      exit 2
    }
    echo "Pinned whisper.cpp checkout already present: ${actual_revision}"
  else
    if [[ -n "$(find "${vendor_dir}" -mindepth 1 -maxdepth 1 ! -name PINNED.md ! -name REVISION -print -quit)" ]]; then
      echo "error: Vendor/whisper.cpp contains unexpected files; refusing to clone into it" >&2
      exit 2
    fi
    temporary_checkout="$(mktemp -d "${TMPDIR:-/tmp}/macspeechtranslator-whisper.XXXXXX")"
    trap 'rm -rf "${temporary_checkout}"' EXIT
    git clone --depth 1 --branch v1.8.3 https://github.com/ggml-org/whisper.cpp.git "${temporary_checkout}/whisper.cpp"
    cp -R "${temporary_checkout}/whisper.cpp/." "${vendor_dir}/"
    actual_revision="$(git -C "${vendor_dir}" rev-parse HEAD)"
    [[ "${actual_revision}" == "${expected_revision}" ]] || {
      echo "error: fetched whisper.cpp revision does not match ${expected_revision}" >&2
      exit 2
    }
    echo "Fetched pinned whisper.cpp checkout: ${actual_revision}"
    rm -rf "${temporary_checkout}"
    trap - EXIT
  fi
fi
