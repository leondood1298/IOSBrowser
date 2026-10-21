// swift-tools-version: 6.0
import PackageDescription

// Turns downloaded HLS segments into MP4 files without re-encoding: MPEG-TS (H.264 or HEVC
// video, AAC audio) and packed AAC audio, plus AES-128 segment decryption. Apple-only
// (CoreMedia, AVFoundation, CommonCrypto); tested with `swift test` on macOS.
let package = Package(
    name: "MediaKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MediaKit", targets: ["MediaKit"]),
    ],
    targets: [
        .target(name: "MediaKit"),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit"]),
    ],
    swiftLanguageModes: [.v5]
)
