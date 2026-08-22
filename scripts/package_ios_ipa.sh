#!/usr/bin/env bash
set -euo pipefail

app_path="${1:-build/ios/iphoneos/Runner.app}"
output_path="${2:-}"

if [[ ! -d "$app_path" ]]; then
  echo "iOS app bundle not found: $app_path" >&2
  exit 1
fi

version="$(awk '/^version:/ {print $2; exit}' pubspec.yaml)"
if [[ -z "$output_path" ]]; then
  output_path="dist/NAI_Launcher_iOS_${version}_TrollStore.ipa"
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mkdir -p "$work_dir/Payload" "$(dirname "$output_path")"
output_dir="$(cd "$(dirname "$output_path")" && pwd)"
output_file="$output_dir/$(basename "$output_path")"
cp -R "$app_path" "$work_dir/Payload/Runner.app"

# TrollStore accepts an ad-hoc signed app. Flutter's --no-codesign output is
# unsigned, so sign the complete bundle when codesign is available on macOS.
if command -v codesign >/dev/null 2>&1; then
  codesign \
    --force \
    --deep \
    --sign - \
    --timestamp=none \
    "$work_dir/Payload/Runner.app"
fi

rm -f "$output_file"
(
  cd "$work_dir"
  /usr/bin/zip -qry "$output_file" Payload
)

echo "Created $output_path"
