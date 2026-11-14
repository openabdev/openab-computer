// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "oab-computer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "oab-computer", targets: ["oab-computer"]),
        .library(name: "InstanceMCPCore", targets: ["InstanceMCPCore"]),
    ],
    targets: [
        // Everything testable: JSON-RPC, MCP dispatch, HTTP/1.1 parsing, auth, tools.
        .target(
            name: "InstanceMCPCore",
            path: "Sources/InstanceMCPCore",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        // Thin CLI: flag parsing + wiring. No logic worth testing lives here.
        .executableTarget(
            name: "oab-computer",
            dependencies: ["InstanceMCPCore"],
            path: "Sources/oab-computer"
        ),
        .testTarget(
            name: "InstanceMCPCoreTests",
            // The executable is a dependency only so it is built beside the tests: one test runs it with the hidden
            // permission-check argument.
            dependencies: ["InstanceMCPCore", "oab-computer"],
            path: "Tests/InstanceMCPCoreTests"
        ),
    ]
)
