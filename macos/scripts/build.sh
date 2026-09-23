#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
repo="$PWD"
output="$repo/dist/macos"
app="$output/Codex Account Switcher.app"
if [[ -e "$output" ]]; then
  echo 'dist/macos already exists; use a fresh checkout/build directory. Nothing overwritten.' >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  swift build --package-path macos -c release --arch "$arch" --product CodexAccountSwitcher
  bin=$(swift build --package-path macos -c release --arch "$arch" --show-bin-path)
  cp "$bin/CodexAccountSwitcher" "$output/switcher-$arch"
done
lipo -create "$output/switcher-arm64" "$output/switcher-x86_64" -output "$app/Contents/MacOS/CodexAccountSwitcher"
cp macos/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - --identifier io.github.sheyinjue-a11y.codex-account-switcher "$app"
codesign --verify --deep --strict --verbose=2 "$app"
lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/CodexAccountSwitcher"
"$app/Contents/MacOS/CodexAccountSwitcher" --render-preview "$output/macos-preview.png"
cp macos/README.md "$output/请先阅读.md"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/Codex-Account-Switcher-macOS-universal.zip"
cd "$output"
shasum -a 256 Codex-Account-Switcher-macOS-universal.zip > SHA256SUMS.txt
echo "Built $app (ad-hoc signed, not notarized)"
