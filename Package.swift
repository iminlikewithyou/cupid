// swift-tools-version: 6.0
// Mactopia: a macOS launcher for Heartopia on Recall's Wine + Rosetta + DXMT runtime.
// No third-party dependencies: the CLI uses a small hand-rolled argument parser
// (swift-argument-parser could not be resolved offline).
import PackageDescription

let package = Package(
    name: "Mactopia",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MactopiaCore", targets: ["MactopiaCore"]),
        .executable(name: "mactopia", targets: ["mactopia"]),
        .executable(name: "MactopiaApp", targets: ["MactopiaApp"]),
    ],
    targets: [
        // The dxmt.conf template is compiled in (DxmtConfig.template); Resources/config/dxmt.conf
        // is the same text for packaging, and a test keeps the two identical.
        .target(name: "MactopiaCore"),
        .executableTarget(name: "mactopia", dependencies: ["MactopiaCore"]),
        // The app shell (scripts/build-app.sh installs the binary as Contents/MacOS/Mactopia).
        .executableTarget(name: "MactopiaApp", dependencies: ["MactopiaCore"], path: "App/Sources"),
        .testTarget(name: "MactopiaCoreTests", dependencies: ["MactopiaCore"]),
    ]
)
