#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
export COPYFILE_DISABLE=1
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/usagebar-package.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
cache_root="${USAGEBAR_BUILD_ROOT:-$root/.build}"
mkdir -p "$cache_root" "$root/dist"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/swift-cache"
common=(--cache-path "$cache_root/spm-cache" --config-path "$cache_root/spm-config" --security-path "$cache_root/spm-security")
if [[ "${USAGEBAR_DISABLE_BUILD_SANDBOX:-0}" == "1" ]]; then common+=(--disable-sandbox --build-system native); fi

build_arch() {
    local arch="$1"
    swift build "${common[@]}" --scratch-path "$cache_root/$arch" --arch "$arch" -c release --product UsageBar
    local bin_dir
    bin_dir="$(swift build "${common[@]}" --scratch-path "$cache_root/$arch" --arch "$arch" -c release --show-bin-path)"
    cp "$bin_dir/UsageBar" "$cache_root/UsageBar-$arch"
}

if [[ "${1:-}" == "--universal" ]]; then
    build_arch arm64
    build_arch x86_64
    lipo -create "$cache_root/UsageBar-arm64" "$cache_root/UsageBar-x86_64" -output "$cache_root/UsageBar"
else
    build_arch "$(uname -m)"
    cp "$cache_root/UsageBar-$(uname -m)" "$cache_root/UsageBar"
fi

app="$staging_root/UsageBar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$cache_root/UsageBar" "$app/Contents/MacOS/UsageBar"
chmod +x "$app/Contents/MacOS/UsageBar"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/THIRD_PARTY_NOTICES.txt" "$root/LICENSE" "$app/Contents/Resources/"
swift "$root/scripts/make-icon.swift" "$cache_root/UsageBar.iconset"
iconutil -c icns "$cache_root/UsageBar.iconset" -o "$app/Contents/Resources/AppIcon.icns"
sign_identity="${USAGEBAR_SIGN_IDENTITY:--}"
if [[ "$sign_identity" == "-" ]]; then
    codesign --force --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$sign_identity" "$app"
fi
codesign --verify --deep --strict "$app"
ditto -c -k --norsrc --keepParent "$app" "$root/dist/UsageBar-macOS.zip"
# External ExFAT volumes otherwise put AppleDouble sidecars inside signed bundles.
destination="$root/dist/UsageBar.app"
rm -rf "$destination"
ditto --norsrc --noextattr "$app" "$destination"
find "$destination" -name '._*' -type f -delete
codesign --verify --deep --strict "$destination"
printf '\nBuilt: %s\nArchive: %s\n' "$destination" "$root/dist/UsageBar-macOS.zip"
