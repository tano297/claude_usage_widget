// swift-tools-version:5.9
import PackageDescription

// This package exists so the shared data layer (parsing, formatting, model) can be built and
// checked with the plain Swift toolchain — no Xcode required. The same Shared/*.swift files are
// also compiled into the app and widget targets by the Xcode project (see project.yml).
//
//   swift run DataLayerCheck    # validate parsing/formatting against fixtures
//
let package = Package(
    name: "ClaudeUsageCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClaudeUsageCore", targets: ["ClaudeUsageCore"]),
        .executable(name: "DataLayerCheck", targets: ["DataLayerCheck"]),
    ],
    targets: [
        .target(name: "ClaudeUsageCore", path: "Shared"),
        .executableTarget(
            name: "DataLayerCheck",
            dependencies: ["ClaudeUsageCore"],
            path: "Tools/DataLayerCheck"
        ),
    ]
)
