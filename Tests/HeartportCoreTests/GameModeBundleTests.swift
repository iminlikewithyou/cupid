import XCTest
@testable import HeartportCore

/// Compares the Swift generator with the xdt.app the spike made with game_mode_app.py, apart
/// from what bundle version 2 added (display name, icon, version keys). Reads an installed
/// runtime only (copies its loader to a temporary engine); skipped when no runtime is
/// installed on this machine.
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
        try GameModeBundle.create(runtime: engine, minimumMacOS: "15.0", identifier: identifier, fallbackIcon: nil)
        try GameModeBundle.check(runtime: engine, identifier: identifier)

        let made = engine.appendingPathComponent(GameModeBundle.relativePath)
        let added = ["CFBundleDisplayName", "CFBundleIconFile", GameModeBundle.versionKey,
                     GameModeBundle.iconSourceKey, GameModeBundle.iconFromGameTriedKey]
        func plist(_ bundle: URL) throws -> NSDictionary {
            let dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil) as! NSDictionary
            let copy = dict.mutableCopy() as! NSMutableDictionary
            copy.removeObjects(forKeys: added)
            return copy
        }
        XCTAssertEqual(try plist(made), try plist(existing))
        let info = try XCTUnwrap(GameModeBundle.installedInfo(runtime: engine))
        XCTAssertEqual(info["CFBundleName"] as? String, "Heartopia")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Heartopia")
        XCTAssertEqual(info[GameModeBundle.versionKey] as? Int, GameModeBundle.bundleVersion)
        XCTAssertEqual(info[GameModeBundle.iconSourceKey] as? String, "none")
        // Same executable bytes apart from the signature (it now also seals the new Info.plist
        // keys): the copy differs from the loader only in LC_UUID.
        func unsigned(_ bundle: URL) throws -> Data {
            let copy = engine.appendingPathComponent("unsigned-\(UUID().uuidString)")
            try fm.copyItem(at: bundle.appendingPathComponent("Contents/MacOS/wine"), to: copy)
            defer { try? fm.removeItem(at: copy) }
            let out = try ProcessRunner.capture("/usr/bin/codesign", ["--remove-signature", copy.path])
            XCTAssertEqual(out.status, 0, out.stderr)
            return try Data(contentsOf: copy)
        }
        XCTAssertEqual(try unsigned(made), try unsigned(existing))
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

    /// A version 1 bundle (no version key) is regenerated; a bundle made before the game was
    /// installed is regenerated with the game's icon once its exe exists.
    func testRegeneratesOlderBundlesAndPicksUpTheGameIcon() throws {
        guard let installed = installedRuntime() else { throw XCTSkip("no installed runtime with xdt.app") }
        let fm = FileManager.default
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        let loader = paths.runtime.appendingPathComponent(GameModeBundle.loaderPath)
        try fm.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: installed.appendingPathComponent(GameModeBundle.loaderPath), to: loader)
        let installer = RuntimeInstaller(paths: paths)

        // Fresh: no game yet, Heartport's icon (when one is found) or none.
        XCTAssertTrue(try installer.ensureGameModeBundle())
        XCTAssertNil(GameModeBundle.staleReason(runtime: paths.runtime, gameExe: paths.gameExe))
        XCTAssertNotEqual(GameModeBundle.installedInfo(runtime: paths.runtime)?[GameModeBundle.iconSourceKey] as? String, "game")

        // Version 1: the key is absent.
        let plistURL = paths.gameModeApp.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(GameModeBundle.installedInfo(runtime: paths.runtime))
        info.removeValue(forKey: GameModeBundle.versionKey)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plistURL)
        XCTAssertEqual(GameModeBundle.staleReason(runtime: paths.runtime, gameExe: paths.gameExe), "bundle version 1 -> 2")
        XCTAssertTrue(try installer.ensureGameModeBundle())
        try GameModeBundle.check(runtime: paths.runtime)
        XCTAssertNil(GameModeBundle.staleReason(runtime: paths.runtime, gameExe: paths.gameExe))

        // The game arrives: its icon replaces Heartport's.
        let png = try makePNG(size: 256, red: 1)
        try fm.createDirectory(at: paths.gameExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(makePE(resources: [(3, 1, png), (14, 1, makeGroup([(256, 256, 32, png.count, 1)]))])).write(to: paths.gameExe)
        XCTAssertEqual(GameModeBundle.staleReason(runtime: paths.runtime, gameExe: paths.gameExe), "the game's icon is available now")
        XCTAssertTrue(try installer.ensureGameModeBundle())
        try GameModeBundle.check(runtime: paths.runtime)
        info = try XCTUnwrap(GameModeBundle.installedInfo(runtime: paths.runtime))
        XCTAssertEqual(info[GameModeBundle.iconSourceKey] as? String, "game")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "Heartopia")
        XCTAssertTrue(fm.fileExists(atPath: paths.gameModeApp.appendingPathComponent("Contents/Resources/Heartopia.icns").path))
        XCTAssertNil(GameModeBundle.staleReason(runtime: paths.runtime, gameExe: paths.gameExe))
        XCTAssertFalse(try installer.ensureGameModeBundle())
    }
}
