// swift-tools-version:5.9
import PackageDescription

// This package exists so the shared data layer (parsing, formatting, model) can be built and
// checked with the plain Swift toolchain — no Xcode required. The same Shared/*.swift files are
// also compiled into the app and widget targets by the Xcode project (see project.yml).
//
//   swift run DataLayerCheck    # validate parsing/formatting against fixtures
//
// RosterCore builds two app files (the roster OAuth client and the per-account sync) so the checks
// can drive them with a stubbed URLSession and an in-memory token store. The app compiles the same
// files directly; the widget never does.
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
        .target(
            name: "RosterCore",
            dependencies: ["ClaudeUsageCore"],
            path: "ClaudeUsageApp",
            exclude: ["AccountsWindow.swift", "ClaudeUsageApp.swift", "Info.plist", "Notifications.swift",
                      "RosterController.swift", "RosterLogin.swift", "RosterSessionStore.swift"],
            sources: ["RosterAPI.swift", "RosterSync.swift"]
        ),
        .executableTarget(
            name: "DataLayerCheck",
            dependencies: ["ClaudeUsageCore", "RosterCore"],
            path: "Tools/DataLayerCheck"
        ),
    ]
)
