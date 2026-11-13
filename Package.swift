// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "oab-instance-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "oab-instance-mcp", targets: ["oab-instance-mcp"]),
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
            name: "oab-instance-mcp",
            dependencies: ["InstanceMCPCore"],
            path: "Sources/oab-instance-mcp"
        ),
        .testTarget(
            name: "InstanceMCPCoreTests",
            // The executable is a dependency only so it is built beside the tests: one test runs it with the hidden
            // permission-check argument.
            dependencies: ["InstanceMCPCore", "oab-instance-mcp"],
            path: "Tests/InstanceMCPCoreTests"
        ),
    ]
)
