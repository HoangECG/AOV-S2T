#!/usr/bin/env bash
# Historical name retained for the project checklist. The current Swift Package
# uses a configured local whisper-cli adapter, so this script builds/copies that
# CLI rather than claiming an XCFramework integration exists.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"
source_dir="${project_root}/Vendor/whisper.cpp"
build_dir="${project_root}/.build/whisper.cpp"
output_path="${project_root}/.local/bin/whisper-cli"
configuration="Release"
overwrite=false
clean=false
dry_run=false

usage() {
  cat <<'EOF'
Usage: Scripts/build_whisper_xcframework.sh [options]

Build a local whisper.cpp whisper-cli for the app's explicit CLI adapter.
No source checkout or model download occurs. Despite its legacy filename, this
does not fabricate an XCFramework because the package does not link one.

Options:
  --source DIR       whisper.cpp checkout (default: Vendor/whisper.cpp)
  --build-dir DIR    CMake build directory (default: .build/whisper.cpp)
  --output PATH      copied whisper-cli output (default: .local/bin/whisper-cli)
  --configuration C  CMake configuration (default: Release)
  --clean            remove the explicit build directory before configuring
  --overwrite        allow replacing --output
  --dry-run          print the commands without modifying files
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source|--build-dir|--output|--configuration)
      [[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --source) source_dir="$2" ;;
        --build-dir) build_dir="$2" ;;
        --output) output_path="$2" ;;
        --configuration) configuration="$2" ;;
      esac
      shift 2
      ;;
    --clean) clean=true; shift ;;
    --overwrite) overwrite=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "${source_dir}" ]] || { echo "error: whisper.cpp source directory is missing: ${source_dir}" >&2; exit 2; }
[[ -f "${source_dir}/CMakeLists.txt" ]] || { echo "error: not a whisper.cpp CMake checkout: ${source_dir}" >&2; exit 2; }
command -v cmake >/dev/null || { echo "error: cmake is required" >&2; exit 2; }

if [[ -f "${source_dir}/REVISION" ]] && command -v git >/dev/null; then
  expected_revision="$(tr -d '[:space:]' < "${source_dir}/REVISION")"
  actual_revision="$(git -C "${source_dir}" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "${expected_revision}" && -n "${actual_revision}" && "${expected_revision}" != "${actual_revision}" ]]; then
    echo "error: Vendor/whisper.cpp revision does not match REVISION metadata" >&2
    echo "expected: ${expected_revision}" >&2
    echo "actual:   ${actual_revision}" >&2
    exit 2
  fi
fi

if [[ -e "${output_path}" && "${overwrite}" != true ]]; then
  echo "error: refusing to overwrite ${output_path}; pass --overwrite explicitly" >&2
  exit 2
fi

configure_command=(cmake -S "${source_dir}" -B "${build_dir}" -DCMAKE_BUILD_TYPE="${configuration}" -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DGGML_METAL=ON)
build_command=(cmake --build "${build_dir}" --config "${configuration}" --target whisper-cli)

printf 'Configure: '; printf '%q ' "${configure_command[@]}"; printf '\n'
printf 'Build:     '; printf '%q ' "${build_command[@]}"; printf '\n'
if [[ "${dry_run}" == true ]]; then
  exit 0
fi

if [[ "${clean}" == true && -d "${build_dir}" ]]; then
  build_parent="$(cd "$(dirname "${build_dir}")" && pwd -P)"
  resolved_build_dir="${build_parent}/$(basename "${build_dir}")"
  if [[ "${resolved_build_dir}" == "/" || "${resolved_build_dir}" == "${project_root}" ]]; then
    echo "error: refusing to remove a broad build directory: ${resolved_build_dir}" >&2
    exit 2
  fi
  rm -rf -- "${resolved_build_dir}"
fi
"${configure_command[@]}"
"${build_command[@]}"

cli_path=""
for candidate in "${build_dir}/bin/whisper-cli" "${build_dir}/bin/main" "${build_dir}/whisper-cli"; do
  if [[ -x "${candidate}" ]]; then
    cli_path="${candidate}"
    break
  fi
done
[[ -n "${cli_path}" ]] || { echo "error: CMake completed but whisper-cli was not found in ${build_dir}" >&2; exit 2; }

mkdir -p "$(dirname "${output_path}")"
cp "${cli_path}" "${output_path}"
chmod u+x "${output_path}"
echo "Built local whisper-cli: ${output_path}"
