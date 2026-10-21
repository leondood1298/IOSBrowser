// swift-tools-version: 6.0
import PackageDescription

// Platform-independent browser logic (Foundation only), so it can be unit-tested quickly
// with `swift test` on macOS CI or any machine with a Swift toolchain.
let package = Package(
    name: "BrowserCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
    ],
    targets: [
        .target(name: "BrowserCore"),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
    ]
)
