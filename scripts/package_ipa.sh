#!/usr/bin/env bash
# Packages the app from an .xcarchive into an unsigned IPA.
# Usage: bash scripts/package_ipa.sh <archive> <output dir> <ipa name without extension>
set -euo pipefail

archive="$1"
out="$2"
name="$3"
app="$archive/Products/Applications/Browser.app"

[ -d "$app" ] || { echo "No app found at $app" >&2; exit 1; }

# Every library the app loads from its own bundle (@rpath) must be in it, or it can't launch.
missing=0
for binary in "$app/Browser" "$app"/PlugIns/*.appex/*; do
    [ -f "$binary" ] && [ -x "$binary" ] || continue
    for library in $(otool -L "$binary" | awk '/@rpath\//{print $1}'); do
        relative="${library#@rpath/}"
        if [ ! -e "$app/Frameworks/$relative" ]; then
            echo "Not in the app bundle: $relative (loaded by $(basename "$binary"))" >&2
            missing=1
        fi
    done
done
[ "$missing" -eq 0 ] || exit 1
rm -rf "$out/Payload"
mkdir -p "$out/Payload"
cp -R "$app" "$out/Payload/"
# The share extension goes in its own copy of the IPA, in case the signing service can't sign
# app extensions; the main IPA leaves it out.
if [ -d "$out/Payload/Browser.app/PlugIns" ]; then
    (cd "$out" && rm -f "$name-with-share-extension.ipa" && zip -qry "$name-with-share-extension.ipa" Payload)
    rm -rf "$out/Payload/Browser.app/PlugIns"
fi
(cd "$out" && rm -f "$name.ipa" && zip -qry "$name.ipa" Payload)

echo "Architectures: $(lipo -archs "$out/Payload/Browser.app/Browser")"
plutil -p "$out/Payload/Browser.app/Info.plist" |
    grep -E '"(CFBundleIdentifier|CFBundleShortVersionString|CFBundleVersion|MinimumOSVersion)"' || true
plutil -extract UIDeviceFamily json -o - "$out/Payload/Browser.app/Info.plist" || true
ls -lh "$out/$name.ipa"
