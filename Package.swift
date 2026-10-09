// swift-tools-version:6.0
import PackageDescription

// Library-only package. There is deliberately no executable or app target here:
// the runnable demo is a separate Xcode project in its own repository
// (video-feed-readiness-kit-demo-app) that consumes this package by release tag.
let package = Package(
    name: "FeedReadiness",
    // Only platforms CI actually builds are declared (Linux builds the same
    // module; it has no platform-specific code).
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FeedReadiness", targets: ["FeedReadiness"]),
    ],
    targets: [
        .target(name: "FeedReadiness"),
        .testTarget(name: "FeedReadinessTests", dependencies: ["FeedReadiness"]),
    ]
)
