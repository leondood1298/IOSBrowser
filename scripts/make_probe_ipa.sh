#!/usr/bin/env bash
# Builds "Browser Probe": a copy of the app that asks for the default-browser entitlement
# and declares the http/https URL schemes. If it installs through Signulous and shows up under
# Settings › Apps › Default Browser App, the signing profile allows that entitlement.
# Usage: bash scripts/make_probe_ipa.sh <Browser.app> <output dir> <ipa name without extension>
set -euo pipefail

source_app="$1"
out="$2"
name="$3"
work="$out/probe"

rm -rf "$work"
mkdir -p "$work/Payload"
cp -R "$source_app" "$work/Payload/"
app="$work/Payload/Browser.app"
plist="$app/Info.plist"

plutil -replace CFBundleIdentifier -string "io.github.leondood1298.browser.probe" "$plist"
plutil -replace CFBundleDisplayName -string "Browser Probe" "$plist"
plutil -insert CFBundleURLTypes.1 -json '{"CFBundleURLName":"web","CFBundleURLSchemes":["http","https"]}' "$plist"

codesign --force --sign - --timestamp=none --entitlements scripts/probe.entitlements "$app"
codesign -d --entitlements - "$app" 2>/dev/null || true

(cd "$work" && rm -f "$name.ipa" && zip -qry "../$name.ipa" Payload)
rm -rf "$work"
ls -lh "$out/$name.ipa"
