// swift-tools-version:5.10
// AI CreditPulse — menu bar credit tracker for macOS.
import PackageDescription

let package = Package(
    name: "AICreditPulse",
    platforms: [.macOS(.v14)],
    targets: [
        // Non-UI layer: env store, HTTP cache, provider adapters, registry,
        // plus the four status-tinted menubar icon PNGs (Resources/).
        .target(
            name: "AICreditPulseCore",
            path: "Sources/AICreditPulseCore",
            resources: [.copy("Resources")]
        ),

        // The menu bar app.
        .executableTarget(
            name: "AICreditPulse",
            dependencies: ["AICreditPulseCore"],
            path: "Sources/AICreditPulse"
        ),

        // Headless smoke test: exercises the Core layer without the GUI
        // (usable from CI or a sandboxed shell; the app needs WindowServer).
        .executableTarget(
            name: "AICreditPulseSmoke",
            dependencies: ["AICreditPulseCore"],
            path: "Sources/AICreditPulseSmoke"
        ),
    ]
)
