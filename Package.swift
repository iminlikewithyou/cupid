// swift-tools-version: 6.0
// Heartport: a macOS launcher for Heartopia on Recall's Wine + Rosetta + DXMT runtime.
// No third-party dependencies: the CLI uses a small hand-rolled argument parser
// (swift-argument-parser could not be resolved offline).
import PackageDescription

let package = Package(
    name: "Heartport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HeartportCore", targets: ["HeartportCore"]),
        .executable(name: "heartport", targets: ["heartport"]),
        .executable(name: "HeartportApp", targets: ["HeartportApp"]),
    ],
    targets: [
        // The dxmt.conf template is compiled in (DxmtConfig.template); Resources/config/dxmt.conf
        // is the same text for packaging, and a test keeps the two identical.
        .target(name: "HeartportCore"),
        .executableTarget(name: "heartport", dependencies: ["HeartportCore"]),
        // The app shell (scripts/build-app.sh installs the binary as Contents/MacOS/Heartport).
        .executableTarget(name: "HeartportApp", dependencies: ["HeartportCore"], path: "App/Sources"),
        .testTarget(name: "HeartportCoreTests", dependencies: ["HeartportCore"]),
    ]
)
