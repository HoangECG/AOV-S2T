#!/usr/bin/env bash
# Builds the Swift Package executable and places it in a minimal local .app
# bundle. The bundle is generated under .build and is never source-controlled.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/.." && pwd)"

cd "${project_root}"
swift build -c release --product MacSpeechTranslator
bin_path="$(swift build -c release --show-bin-path)"
app_path="${bin_path}/MacSpeechTranslator.app"
contents_path="${app_path}/Contents"

mkdir -p "${contents_path}/MacOS"
cp "${project_root}/App/Info.plist" "${contents_path}/Info.plist"
cp "${bin_path}/MacSpeechTranslator" "${contents_path}/MacOS/MacSpeechTranslator"
chmod u+x "${contents_path}/MacOS/MacSpeechTranslator"

echo "Built local app bundle: ${app_path}"
echo "Run: open \"${app_path}\""
