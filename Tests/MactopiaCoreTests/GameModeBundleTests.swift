import XCTest
@testable import MactopiaCore

/// Compares the Swift generator with the xdt.app the spike made with game_mode_app.py.
/// Reads the installed runtime only (copies its loader to a temporary engine); skipped when
/// the runtime is not installed on this machine.
final class GameModeBundleTests: XCTestCase {
    func testMatchesSpikeBundle() throws {
        let installed = Paths.resolve(environment: [:]).runtime
        let existing = installed.appendingPathComponent(GameModeBundle.relativePath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: existing.path) else { throw XCTSkip("no installed runtime with xdt.app") }

        let engine = try tempDir()
        let loader = engine.appendingPathComponent(GameModeBundle.loaderPath)
        try fm.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: installed.appendingPathComponent(GameModeBundle.loaderPath), to: loader)
        try GameModeBundle.create(runtime: engine, minimumMacOS: "15.0")
        try GameModeBundle.check(runtime: engine)

        let made = engine.appendingPathComponent(GameModeBundle.relativePath)
        func plist(_ bundle: URL) throws -> NSDictionary {
            try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil) as! NSDictionary
        }
        XCTAssertEqual(try plist(made), try plist(existing))
        // Same executable bytes, signature included (ad hoc signing is deterministic).
        XCTAssertEqual(try Data(contentsOf: made.appendingPathComponent("Contents/MacOS/wine")),
                       try Data(contentsOf: existing.appendingPathComponent("Contents/MacOS/wine")))
        XCTAssertThrowsError(try GameModeBundle.create(runtime: engine))
    }
}
