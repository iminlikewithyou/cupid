import XCTest
@testable import HeartportCore

final class PathsStateTests: XCTestCase {
    func testDefaultResolution() {
        let paths = Paths.resolve(environment: [:], userHome: URL(fileURLWithPath: "/Users/p"))
        XCTAssertEqual(paths.dataRoot.path, "/Users/p/Library/Application Support/Heartport")
        XCTAssertEqual(paths.runtimeVersion, "phase2-20261007.3")
        XCTAssertEqual(paths.runtime.path, "/Users/p/Library/Application Support/Heartport/runtime/phase2-20261007.3")
        XCTAssertEqual(paths.gameModeApp.path, paths.runtime.path + "/lib/wine/game-mode/xdt.app")
        XCTAssertEqual(paths.gameExe.path, paths.dataRoot.path + "/prefix/drive_c/TapTapGlobal/Apps/231364/xdt.exe")
        XCTAssertEqual(paths.gameFileInfo.lastPathComponent, "GameFileInfo.json")
        XCTAssertEqual(paths.launcherExe.path, paths.dataRoot.path + "/prefix/drive_c/Program Files/TapTapGlobal/TapTapGlobal.exe")
        XCTAssertEqual(paths.dxmtConf.path, paths.dataRoot.path + "/dxmt.conf")
        XCTAssertEqual(paths.stateFile.path, paths.dataRoot.path + "/state.json")
        XCTAssertEqual(paths.layoutDirectories.map { String($0.path.dropFirst(paths.dataRoot.path.count + 1)) },
                       ["runtime", "prefix", "cache/shaders", "cache/pipelines", "home", "tmp", "logs", "downloads"])
    }

    func testOverrides() {
        let home = URL(fileURLWithPath: "/Users/p")
        XCTAssertEqual(Paths.resolve(environment: ["HEARTPORT_DATA_ROOT": "/tmp/m"], userHome: home).dataRoot.path, "/tmp/m")
        XCTAssertEqual(Paths.resolve(dataOverride: "/tmp/x/../y", environment: ["HEARTPORT_DATA_ROOT": "/tmp/m"]).dataRoot.path, "/tmp/y")
        XCTAssertFalse(Paths.resolve(dataOverride: "~/m", environment: [:]).dataRoot.path.contains("~"))
        XCTAssertEqual(Paths.resolve(environment: ["HEARTPORT_DATA_ROOT": ""], userHome: home).dataRoot.path,
                       "/Users/p/Library/Application Support/Heartport")
        XCTAssertEqual(Paths.environmentOverride(["HEARTPORT_DATA_ROOT": "/tmp/h"])?.name, "HEARTPORT_DATA_ROOT")
        XCTAssertNil(Paths.environmentOverride(["OTHER_DATA_ROOT": "/tmp/r"]))
    }

    func testWindowsPath() {
        XCTAssertEqual(Paths.windowsPath(URL(fileURLWithPath: "/Users/p/Library/Application Support/Heartport/dxmt.conf")),
                       #"Z:\Users\p\Library\Application Support\Heartport\dxmt.conf"#)
    }

    func testSpikeStateIsAdopted() throws {
        let state = try AppState.decode(Data(#"{"runtime":"phase2-20261007.3","prefix":"created"}"#.utf8))
        XCTAssertEqual(state.runtime, "phase2-20261007.3")
        XCTAssertEqual(state.prefix, "created")
        XCTAssertNil(state.hud)
        let paths = Paths(dataRoot: try tempDir())
        try write(#"{"runtime":"phase2-20261007.3","prefix":"created","unknown":1}"#, to: paths.stateFile)
        var loaded = AppState.load(paths)
        XCTAssertEqual(loaded, state)
        loaded.hud = true
        XCTAssertTrue(try loaded.save(paths))
        XCTAssertFalse(try loaded.save(paths)) // unchanged: no write
        XCTAssertEqual(AppState.load(paths).hud, true)
    }

    func testCorruptStateIsEmpty() throws {
        let paths = Paths(dataRoot: try tempDir())
        try write("not json", to: paths.stateFile)
        XCTAssertEqual(AppState.load(paths), AppState())
    }

    func testLogRotationKeepsNewest() throws {
        let dir = try tempDir()
        let log = dir.appendingPathComponent("game.log")
        for i in 0..<5 {
            try write("run \(i)", to: log)
            try Logs.rotate(log, keep: 3, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
        }
        let rotated = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("game.") }.sorted()
        XCTAssertEqual(rotated.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(rotated.last!), encoding: .utf8), "run 4")
    }
}

final class SessionTests: XCTestCase {
    func testArgv0Parsing() {
        var buf: [UInt8] = [2, 0, 0, 0]
        buf += Array("/rt/lib/wine/game-mode/xdt.app/Contents/MacOS/wine".utf8) + [0, 0, 0, 0]
        buf += Array(#"C:\TapTapGlobal\Apps\231364\xdt.exe"#.utf8) + [0] + Array("arg".utf8) + [0]
        XCTAssertEqual(LiveProcesses.parseArgv0(buf), #"C:\TapTapGlobal\Apps\231364\xdt.exe"#)
        XCTAssertNil(LiveProcesses.parseArgv0([1, 0, 0, 0]))
    }

    func testSnapshotClassification() {
        let rt = "/d/runtime/phase2-20261007.3"
        let snap = SessionSnapshot(processes: [
            .init(pid: 10, path: "\(rt)/bin/wineserver", argv0: "\(rt)/lib/wine/../../bin/wineserver"),
            .init(pid: 11, path: "\(rt)/lib/wine/x86_64-unix/wine", argv0: #"C:\windows\system32\services.exe"#),
            .init(pid: 12, path: "\(rt)/lib/wine/game-mode/xdt.app/Contents/MacOS/wine", argv0: #"C:\TapTapGlobal\Apps\231364\XDT.EXE"#),
            .init(pid: 13, path: "\(rt)/lib/wine/x86_64-unix/wine", argv0: #"C:\Program Files\TapTapGlobal\TapTapGlobal.exe"#),
            .init(pid: 14, path: "\(rt)/lib/wine/x86_64-unix/wine", argv0: "/d/downloads/TapTap_Global_PC_Setup_0.3.0.1000_coop-pc-id231364-.exe"),
            .init(pid: 15, path: "\(rt)/lib/wine/x86_64-unix/wine", argv0: #"C:\TapTapGlobal\Apps\231364\UnityCrashHandler64.exe"#),
        ], runtimesDir: "/d/runtime", wineserverPath: "\(rt)/bin/wineserver")
        XCTAssertTrue(snap.isAlive)
        XCTAssertEqual(snap.wineservers.map(\.pid), [10])
        XCTAssertEqual(snap.game?.pid, 12)
        XCTAssertEqual(snap.launcher.map(\.pid), [13])
        XCTAssertEqual(snap.installer.map(\.pid), [14])
        XCTAssertEqual(SessionSnapshot(processes: [], runtimesDir: "/d/runtime", wineserverPath: "").isAlive, false)
    }

    /// A live process whose binary sits at `<data>/runtime/<v>/bin/wineserver` is detected through
    /// proc_listallpids + proc_pidpath (a copy of /bin/sleep stands in; no Wine involved).
    func testLiveWineserverDetection() throws {
        let paths = Paths(dataRoot: try tempDir())
        try FileManager.default.createDirectory(at: paths.wineserver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: paths.wineserver.path)
        XCTAssertFalse(SessionSnapshot.take(paths).isAlive)
        let p = Process()
        p.executableURL = paths.wineserver
        p.arguments = ["30"]
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        var alive = false
        for _ in 0..<50 where !alive { alive = SessionSnapshot.take(paths).isAlive; if !alive { Thread.sleep(forTimeInterval: 0.1) } }
        XCTAssertTrue(alive)
        let snap = SessionSnapshot.take(paths)
        XCTAssertEqual(snap.wineservers.first?.pid, p.processIdentifier)
        XCTAssertEqual(snap.wineservers.first?.argv0, paths.wineserver.path)
        XCTAssertThrowsError(try SessionGuard.requireIdle(paths, to: "test")) { error in
            XCTAssertEqual((error as? HeartportError)?.kind, .sessionAlive)
        }
        // Prefix changes refuse while it lives.
        XCTAssertThrowsError(try PrefixSetup(paths: paths).apply([.winecfgWin10]))
    }

    func testWelcomedRoundTripsAndDefaultsToAbsent() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        XCTAssertNil(AppState.load(paths).welcomed)
        let spike = try AppState.decode(Data(#"{"runtime":"r","prefix":"created"}"#.utf8))
        XCTAssertNil(spike.welcomed)
        try AppState.update(paths) { $0.welcomed = true }
        XCTAssertEqual(AppState.load(paths).welcomed, true)
        XCTAssertTrue(String(decoding: try Data(contentsOf: paths.stateFile), as: UTF8.self).contains(#""welcomed" : true"#))
    }

    func testNativeFullscreenSettingDefaultsOffAndDrivesTheLaunch() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        XCTAssertNil(AppState.load(paths).nativeFullscreen)
        XCTAssertFalse(GameLauncher.Options(state: AppState.load(paths)).nativeFullscreen)
        try AppState.update(paths) { $0.nativeFullscreen = true; $0.hud = true }
        let state = AppState.load(paths)
        XCTAssertEqual(state.nativeFullscreen, true)
        XCTAssertTrue(String(decoding: try Data(contentsOf: paths.stateFile), as: UTF8.self).contains(#""nativeFullscreen" : true"#))
        let options = GameLauncher.Options(state: state)
        XCTAssertTrue(options.nativeFullscreen)
        XCTAssertTrue(options.hud)
        try AppState.update(paths) { $0.nativeFullscreen = false }
        XCTAssertFalse(GameLauncher.Options(state: AppState.load(paths)).nativeFullscreen)
    }

    func testSetupCompleteShownRoundTripsAndDefaultsToAbsent() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        XCTAssertNil(AppState.load(paths).setupCompleteShown)
        try AppState.update(paths) { $0.setupCompleteShown = true }
        XCTAssertEqual(AppState.load(paths).setupCompleteShown, true)
        XCTAssertTrue(String(decoding: try Data(contentsOf: paths.stateFile), as: UTF8.self).contains(#""setupCompleteShown" : true"#))
    }
}
