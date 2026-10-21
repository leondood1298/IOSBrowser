# Browser

A personal web browser for iPad, built on WebKit. It follows Firefox Focus for browsing and
privacy, and Aloha Browser for downloads, file management and media playback.

## Get the app

- **Latest build of `main`:** [Browser-nightly.ipa](https://github.com/leondood1298/IOSBrowser/releases/download/nightly/Browser-nightly.ipa)
- **Milestone builds:** [Releases](https://github.com/leondood1298/IOSBrowser/releases)

The IPA is unsigned. Upload it to Signulous to sign and install it. The app needs iPadOS 26 or later.

`BrowserProbe-*.ipa` is a test copy that installs alongside the app as "Browser Probe". It asks for
Apple's default-browser entitlement. If it shows up under Settings › Apps › Default Browser App after
installing, the signing profile allows that entitlement and the real app can request it too.

## How it's built

Every build runs on GitHub Actions macOS runners, so no Mac is needed:

| Workflow | When | What it does |
| --- | --- | --- |
| `ci.yml` | Every push and PR | BrowserCore tests, iPad simulator build, unit tests |
| `ipa.yml` | Pushes to `main`, `v*` tags | Unsigned IPA, the rolling `nightly` pre-release, versioned releases |
| `screenshots.yml` | Manual | UI flows on an iPad simulator, saved as screenshots |
| `xcode27-canary.yml` | Pushes to `main` | Checks the project also builds with Xcode 27 (non-blocking) |

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen),
so it isn't checked in. To build on a Mac: `brew install xcodegen && xcodegen generate`, then open
`Browser.xcodeproj`.

## Layout

```
App/                    the iPad app (UIKit shell, SwiftUI panels)
Packages/BrowserCore/   platform-independent logic with fast unit tests (swift test)
Tests/                  app unit tests and UI flows
TestSite/               pages and files served to the UI tests by scripts/testserver.py
scripts/                CI helpers
release-notes/          notes and device checklists for tagged releases
```

## Roadmap

| Milestone | Scope |
| --- | --- |
| M0 | Build pipeline, unsigned IPA, minimal browser |
| M1 | Tabs and tab groups, multi-window, history, bookmarks, zoom, user agents, keyboard shortcuts |
| M2 | Firefox Focus privacy: Erase, tracker blocking, search engines and suggestions, Face ID lock |
| M3 | Download manager with background downloads and a Live Activity |
| M4 | File manager with zip, 7z and RAR |
| M5 | Instant image and PDF viewers, video and music players |
| M6–M7 | Video detection and HLS-to-MP4 downloads |
| M8 | VLC playback for more formats, share extension, polish |

Third-party code and data are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
