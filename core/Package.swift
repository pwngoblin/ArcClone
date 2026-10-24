// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lily",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lily", targets: ["Lily"]),
        .library(name: "LilyCore", targets: ["LilyCore"]),
    ],
    targets: [
        .target(
            name: "LilyCore",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        ),
        .executableTarget(name: "Lily", dependencies: ["LilyCore"]),
        .testTarget(name: "LilyCoreTests", dependencies: ["LilyCore"]),
    ],
    // Swift 6 mode: complete strict-concurrency checking, data races are compile errors.
    // There are no package dependencies; any added must be pinned (`exact:` or `revision:`),
    // which scripts/security-lint.sh enforces.
    swiftLanguageModes: [.v6]
)
