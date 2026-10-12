import XCTest
@testable import CupidCore

final class PathsStateTests: XCTestCase {
    func testDefaultResolution() {
        let paths = Paths.resolve(environment: [:], userHome: URL(fileURLWithPath: "/Users/p"))
        XCTAssertEqual(paths.dataRoot.path, "/Users/p/Library/Application Support/Cupid")
        XCTAssertEqual(paths.runtimeVersion, "phase2-20261007.3")
        XCTAssertEqual(paths.runtime.path, "/Users/p/Library/Application Support/Cupid/runtime/phase2-20261007.3")
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
        XCTAssertEqual(Paths.resolve(environment: ["CUPID_DATA_ROOT": "/tmp/m"], userHome: home).dataRoot.path, "/tmp/m")
        XCTAssertEqual(Paths.resolve(dataOverride: "/tmp/x/../y", environment: ["CUPID_DATA_ROOT": "/tmp/m"]).dataRoot.path, "/tmp/y")
        XCTAssertFalse(Paths.resolve(dataOverride: "~/m", environment: [:]).dataRoot.path.contains("~"))
        XCTAssertEqual(Paths.resolve(environment: ["CUPID_DATA_ROOT": ""], userHome: home).dataRoot.path,
                       "/Users/p/Library/Application Support/Cupid")
        XCTAssertEqual(Paths.environmentOverride(["CUPID_DATA_ROOT": "/tmp/h"])?.name, "CUPID_DATA_ROOT")
        XCTAssertNil(Paths.environmentOverride(["OTHER_DATA_ROOT": "/tmp/r"]))
    }

    func testWindowsPath() {
        XCTAssertEqual(Paths.windowsPath(URL(fileURLWithPath: "/Users/p/Library/Application Support/Cupid/dxmt.conf")),
                       #"Z:\Users\p\Library\Application Support\Cupid\dxmt.conf"#)
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

    func testInstallerStagesToActivate() {
        let rt = "/d/runtime/r"
        func process(_ pid: Int32, _ argv0: String) -> WineProcess { .init(pid: pid, path: "\(rt)/lib/wine/x86_64-unix/wine", argv0: argv0) }
        func window(_ pid: Int32, id: Int? = nil, layer: Int = 0, width: Int = 480, height: Int = 360) -> WindowInfo {
            WindowInfo(id: id ?? Int(pid) * 100, pid: pid, owner: "wine", title: "", layer: layer, x: 0, y: 0, width: width, height: height)
        }
        let snap = SessionSnapshot(processes: [
            process(10, #"C:\windows\system32\services.exe"#),
            process(20, "/d/downloads/TapTap_Global_PC_Setup_0.3.0.1000.exe"),           // language choice
            process(21, #"C:\users\player\AppData\Local\Temp\is-ABC.tmp\setup.exe"#), // install
            process(22, "/d/tmp/finish.exe"),                                                // "Installation complete"
            process(30, #"C:\Program Files\TapTapGlobal\TapTapGlobal.exe"#),
        ], runtimesDir: "/d/runtime", wineserverPath: "\(rt)/bin/wineserver", installerDirs: ["/d/downloads", "/d/tmp"])
        XCTAssertEqual(snap.installer.map(\.pid), [20, 21, 22])
        func check(_ windows: [WindowInfo], _ handled: Set<Int>, _ pids: [Int32], _ ids: Set<Int>, line: UInt = #line) {
            let r = snap.installerWindowsToActivate(windows: windows, handled: handled)
            XCTAssertEqual(r.pids, pids, line: line)
            XCTAssertEqual(r.windowIDs, ids, line: line)
        }
        // Only installer processes with a real window; services and TapTap never.
        let windows = [window(10), window(20), window(21, width: 1, height: 1), window(22, layer: 3), window(30)]
        check(windows, [], [20], [2000])
        check(windows, [2000], [], [])
        // The next stage's window appears: only it is new.
        let later = windows + [window(21)]
        check(later, [2000], [21], [2100])
        check(later + [window(22)], [2000, 2100], [22], [2200])
        check([], [], [], [])
    }

    /// One installer process shows its windows one after another (language, then terms): each
    /// new window is brought forward once, and a dialog over a window still open is too.
    func testInstallerNewWindowsOfOneProcess() {
        let rt = "/d/runtime/r"
        let snap = SessionSnapshot(processes: [
            .init(pid: 20, path: "\(rt)/lib/wine/x86_64-unix/wine", argv0: "/d/downloads/TapTap_Global_PC_Setup_0.3.0.1000.exe"),
        ], runtimesDir: "/d/runtime", wineserverPath: "\(rt)/bin/wineserver", installerDirs: ["/d/downloads"])
        func window(_ id: Int, width: Int = 480) -> WindowInfo {
            WindowInfo(id: id, pid: 20, owner: "wine", title: "", layer: 0, x: 0, y: 0, width: width, height: 360)
        }
        func activate(_ windows: [WindowInfo], _ handled: Set<Int>) -> (pids: [Int32], windowIDs: Set<Int>) {
            snap.installerWindowsToActivate(windows: windows, handled: handled)
        }
        // Language dialog: activated once, then not again while it stays open.
        XCTAssertEqual(activate([window(1)], []).pids, [20])
        XCTAssertEqual(activate([window(1)], []).windowIDs, [1])
        XCTAssertEqual(activate([window(1)], [1]).pids, [])
        // It closes (no windows for a moment), then the terms window opens from the same pid.
        XCTAssertEqual(activate([], [1]).pids, [])
        XCTAssertEqual(activate([window(2)], [1]).pids, [20])
        XCTAssertEqual(activate([window(2)], [1]).windowIDs, [2])
        XCTAssertEqual(activate([window(2)], [1, 2]).pids, [])
        // A dialog opens over the terms window, which stays on screen: activated once, one pid.
        XCTAssertEqual(activate([window(2), window(3)], [1, 2]).pids, [20])
        XCTAssertEqual(activate([window(2), window(3)], [1, 2]).windowIDs, [3])
        XCTAssertEqual(activate([window(2), window(3)], [1, 2, 3]).pids, [])
        // Two new windows of one process at once: the pid once.
        XCTAssertEqual(activate([window(4), window(5), window(6, width: 1)], [1, 2, 3]).pids, [20])
        XCTAssertEqual(activate([window(4), window(5), window(6, width: 1)], [1, 2, 3]).windowIDs, [4, 5])
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
            XCTAssertEqual((error as? CupidError)?.kind, .sessionAlive)
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

    func testFullscreenModeDefaultsToFillNotificationsAndDrivesTheLaunch() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        XCTAssertNil(AppState.load(paths).fullscreenMode)
        XCTAssertEqual(AppState.load(paths).fullscreen, .fillNotifications)
        XCTAssertEqual(GameLauncher.Options(state: AppState.load(paths)).fullscreen, .fillNotifications)
        XCTAssertEqual(GameLauncher.Options().fullscreen, .fillNotifications)
        try AppState.update(paths) { $0.setFullscreen(.fill); $0.hud = true }
        var state = AppState.load(paths)
        XCTAssertEqual(state.fullscreen, .fill)
        XCTAssertTrue(String(decoding: try Data(contentsOf: paths.stateFile), as: UTF8.self)
            .contains(#""fullscreenMode" : "fill""#))
        let options = GameLauncher.Options(state: state)
        XCTAssertEqual(options.fullscreen, .fill)
        XCTAssertTrue(options.hud)
        try AppState.update(paths) { $0.setFullscreen(.space) }
        state = AppState.load(paths)
        XCTAssertEqual(GameLauncher.Options(state: state).fullscreen, .space)
        // An unknown value falls back to the default.
        state.fullscreenMode = "sideways"
        XCTAssertEqual(state.fullscreen, .fillNotifications)
    }

    func testOldNativeFullscreenReadsAsSpace() throws {
        var state = try AppState.decode(Data(#"{"runtime":"r","nativeFullscreen":true}"#.utf8))
        XCTAssertEqual(state.fullscreen, .space)
        XCTAssertEqual(try AppState.decode(Data(#"{"nativeFullscreen":false}"#.utf8)).fullscreen, .fillNotifications)
        // fullscreenMode wins, and choosing a mode drops the old field.
        state.fullscreenMode = "fill"
        XCTAssertEqual(state.fullscreen, .fill)
        state.setFullscreen(.fillNotifications)
        XCTAssertNil(state.nativeFullscreen)
        XCTAssertFalse(String(decoding: try state.encoded(), as: UTF8.self).contains("nativeFullscreen"))
    }

    func testFullscreenArgumentValues() {
        XCTAssertEqual(FullscreenMode(argument: "fill"), .fill)
        XCTAssertEqual(FullscreenMode(argument: "notifications"), .fillNotifications)
        XCTAssertEqual(FullscreenMode(argument: "space"), .space)
        XCTAssertNil(FullscreenMode(argument: "Space"))
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
