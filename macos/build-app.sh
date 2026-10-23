#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -gt 1 || "${1:-}" == --help ]]; then
    printf 'Usage: %s [output.app]\n' "$0"
    [[ $# -le 1 ]] && exit 0 || exit 1
fi
app="${1:-$here/../build/YoloLight Air.app}"
if [[ "$app" != *.app ]]; then
    printf 'Output path must end in .app\n' >&2
    exit 1
fi
# A release uses a fresh temporary output, leaving the running local app alone.
mkdir -p "$(dirname "$app")"
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"

swift build --package-path "$here" --configuration release --product YoloLightMenu
bin_dir="$(swift build --package-path "$here" --configuration release --show-bin-path)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin_dir/YoloLightMenu" "$app/Contents/MacOS/YoloLightMenu"
cp "$here/Support/Info.plist" "$app/Contents/Info.plist"
cp "$here/../LICENSE" "$app/Contents/Resources/LICENSE"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '\nBuilt: %s\n' "$app"
printf 'Launch with: open "%s"\n' "$app"
