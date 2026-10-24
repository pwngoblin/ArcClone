// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArcClone",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ArcClone", targets: ["ArcClone"]),
        .library(name: "ArcCloneCore", targets: ["ArcCloneCore"]),
    ],
    targets: [
        .target(
            name: "ArcCloneCore",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        ),
        .executableTarget(name: "ArcClone", dependencies: ["ArcCloneCore"]),
        .testTarget(name: "ArcCloneCoreTests", dependencies: ["ArcCloneCore"]),
    ],
    // Swift 6 mode: complete strict-concurrency checking, data races are compile errors.
    // There are no package dependencies; any added must be pinned (`exact:` or `revision:`),
    // which scripts/security-lint.sh enforces.
    swiftLanguageModes: [.v6]
)
