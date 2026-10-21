#!/usr/bin/env bash
# Points the rolling "nightly" pre-release at this commit and replaces its IPAs, so
# https://github.com/<owner>/<repo>/releases/download/nightly/Browser-nightly.ipa is always the latest main build.
# Expects VERSION, GITHUB_SHA, GITHUB_RUN_NUMBER and GH_TOKEN in the environment.
set -euo pipefail

cp "out/Browser-$VERSION.ipa" out/Browser-nightly.ipa
cp "out/BrowserProbe-$VERSION.ipa" out/BrowserProbe-nightly.ipa

git tag -f nightly "$GITHUB_SHA"
git push -f origin refs/tags/nightly

notes="Latest build of \`main\`: version $VERSION (build $GITHUB_RUN_NUMBER), commit ${GITHUB_SHA:0:7}.

- **Browser-nightly.ipa**: the app, unsigned. Sign and install it with Signulous.
- **BrowserProbe-nightly.ipa**: a test copy (\"Browser Probe\") that requests the default-browser entitlement."

if gh release view nightly > /dev/null 2>&1; then
    gh release edit nightly --prerelease --title "Nightly ($VERSION)" --notes "$notes"
else
    gh release create nightly --prerelease --title "Nightly ($VERSION)" --notes "$notes" --target "$GITHUB_SHA"
fi
gh release upload nightly out/Browser-nightly.ipa out/BrowserProbe-nightly.ipa --clobber
