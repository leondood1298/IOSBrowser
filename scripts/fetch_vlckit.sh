#!/usr/bin/env bash
# Downloads MobileVLCKit (LGPL v2.1, https://code.videolan.org/videolan/VLCKit) into Vendor/ and
# checks it against the SHA-256 published in its CocoaPods podspec. CI caches Vendor/.
# Usage: bash scripts/fetch_vlckit.sh
set -euo pipefail
VERSION="3.7.3"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz"
SHA256="0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9"
DEST="Vendor/MobileVLCKit.xcframework"

if [ -d "$DEST" ]; then
    echo "MobileVLCKit $VERSION is already in $DEST"
    exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fL --retry 3 --silent --show-error -o "$work/vlckit.tar.xz" "$URL"
echo "$SHA256  $work/vlckit.tar.xz" | shasum -a 256 -c -
mkdir -p "$work/files"
tar -xJf "$work/vlckit.tar.xz" -C "$work/files"
found=$(find "$work/files" -maxdepth 3 -type d -name MobileVLCKit.xcframework | head -1)
if [ -z "$found" ]; then
    echo "MobileVLCKit.xcframework isn't in the archive" >&2
    exit 1
fi
mkdir -p Vendor
mv "$found" "$DEST"
# The app needs only the iOS device and simulator slices.
find "$DEST" -maxdepth 1 -mindepth 1 -type d ! -name "ios-*" -exec rm -rf {} +
find "$DEST" -name "*.dSYM" -prune -exec rm -rf {} +
ls "$DEST"
du -sh "$DEST"
