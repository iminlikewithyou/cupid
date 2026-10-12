import XCTest
@testable import HeartportCore

/// Compares the Swift generator with the xdt.app the spike made with game_mode_app.py.
/// Reads an installed runtime only (copies its loader to a temporary engine); skipped when no
/// runtime is installed on this machine.
final class GameModeBundleTests: XCTestCase {
    func installedRuntime() -> URL? {
        let runtime = Paths(dataRoot: Paths.defaultDataRoot()).runtime
        if FileManager.default.fileExists(atPath: runtime.appendingPathComponent(GameModeBundle.relativePath).path) { return runtime }
        return nil
    }

    func testMatchesSpikeBundle() throws {
        guard let installed = installedRuntime() else { throw XCTSkip("no installed runtime with xdt.app") }
        let existing = installed.appendingPathComponent(GameModeBundle.relativePath)
        let fm = FileManager.default
        // The installed bundle may predate the rename; generate with its identifier to compare bytes.
        let identifier = try XCTUnwrap(GameModeBundle.installedIdentifier(runtime: installed))

        let engine = try tempDir()
        defer { try? fm.removeItem(at: engine) }
        let loader = engine.appendingPathComponent(GameModeBundle.loaderPath)
        try fm.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: installed.appendingPathComponent(GameModeBundle.loaderPath), to: loader)
        try GameModeBundle.create(runtime: engine, minimumMacOS: "15.0", identifier: identifier)
        try GameModeBundle.check(runtime: engine, identifier: identifier)

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

    /// A pre-rename xdt.app is regenerated with app.heartport.heartopia; nothing else changes.
    func testRegeneratesBundleWithOldIdentifier() throws {
        guard let installed = installedRuntime() else { throw XCTSkip("no installed runtime with xdt.app") }
        XCTAssertEqual(GameModeBundle.identifier, "app.heartport.heartopia")
        let fm = FileManager.default
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        let loader = paths.runtime.appendingPathComponent(GameModeBundle.loaderPath)
        try fm.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: installed.appendingPathComponent(GameModeBundle.loaderPath), to: loader)
        let sibling = paths.runtime.appendingPathComponent("lib/wine/game-mode/Overwatch.app/Contents/Info.plist")
        try write("untouched", to: sibling)
        try GameModeBundle.create(runtime: paths.runtime, minimumMacOS: "15.0", identifier: "app.example.old-heartopia")
        let loaderBefore = try Data(contentsOf: loader)

        let installer = RuntimeInstaller(paths: paths)
        XCTAssertTrue(try installer.ensureGameModeBundle())
        XCTAssertEqual(GameModeBundle.installedIdentifier(runtime: paths.runtime), GameModeBundle.identifier)
        try GameModeBundle.check(runtime: paths.runtime)
        XCTAssertEqual(try Data(contentsOf: loader), loaderBefore)
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "untouched")
        XCTAssertFalse(try installer.ensureGameModeBundle()) // now current: kept
    }
}
