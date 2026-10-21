#!/usr/bin/env bash
# Packages the app from an .xcarchive into an unsigned IPA.
# Usage: bash scripts/package_ipa.sh <archive> <output dir> <ipa name without extension>
set -euo pipefail

archive="$1"
out="$2"
name="$3"
app="$archive/Products/Applications/Browser.app"

[ -d "$app" ] || { echo "No app found at $app" >&2; exit 1; }
rm -rf "$out/Payload"
mkdir -p "$out/Payload"
cp -R "$app" "$out/Payload/"
(cd "$out" && rm -f "$name.ipa" && zip -qry "$name.ipa" Payload)

echo "Architectures: $(lipo -archs "$out/Payload/Browser.app/Browser")"
plutil -p "$out/Payload/Browser.app/Info.plist" |
    grep -E '"(CFBundleIdentifier|CFBundleShortVersionString|CFBundleVersion|MinimumOSVersion)"' || true
plutil -extract UIDeviceFamily json -o - "$out/Payload/Browser.app/Info.plist" || true
ls -lh "$out/$name.ipa"
