// swift-tools-version: 6.0
// Cupid: a macOS launcher for Heartopia on Recall's Wine + Rosetta + DXMT runtime.
// No third-party dependencies: the CLI uses a small hand-rolled argument parser
// (swift-argument-parser could not be resolved offline).
import PackageDescription

let package = Package(
    name: "Cupid",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CupidCore", targets: ["CupidCore"]),
        .executable(name: "cupid", targets: ["cupid"]),
        .executable(name: "CupidApp", targets: ["CupidApp"]),
    ],
    targets: [
        // The dxmt.conf template is compiled in (DxmtConfig.template); Resources/config/dxmt.conf
        // is the same text for packaging, and a test keeps the two identical.
        .target(name: "CupidCore"),
        .executableTarget(name: "cupid", dependencies: ["CupidCore"]),
        // The app shell (scripts/build-app.sh installs the binary as Contents/MacOS/Cupid).
        .executableTarget(name: "CupidApp", dependencies: ["CupidCore"], path: "App/Sources"),
        .testTarget(name: "CupidCoreTests", dependencies: ["CupidCore"]),
    ]
)
