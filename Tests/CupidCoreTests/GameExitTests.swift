import XCTest
@testable import CupidCore

final class GameExitTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(GameExit.classify(.init(runSeconds: 3600)), .normal)
        XCTAssertEqual(GameExit.classify(.init(runSeconds: 20)), .normal)
        guard case .crash = GameExit.classify(.init(runSeconds: 19.9)) else { return XCTFail("short run") }
        guard case .crash = GameExit.classify(.init(runSeconds: 3600, crashMarker: true)) else { return XCTFail("marker") }
    }

    func testCrashMarkerOnlyInALogWrittenSinceLaunch() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        XCTAssertFalse(GameExit.crashMarkerInPlayerLog(paths, since: Date()))
        let log = paths.usersDir.appendingPathComponent("player/AppData/LocalLow/xd/Heartopia/Player.log")
        try write("[Net] ok\n", to: log)
        XCTAssertEqual(GameExit.playerLogs(paths).map(\.lastPathComponent), ["Player.log"])
        XCTAssertFalse(GameExit.crashMarkerInPlayerLog(paths, since: Date().addingTimeInterval(-60)))
        try write(String(repeating: "x", count: 300_000) + "\nCrash!!!\n", to: log)
        XCTAssertTrue(GameExit.crashMarkerInPlayerLog(paths, since: Date().addingTimeInterval(-60)))
        // A crash from an earlier session does not count.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: log.path)
        XCTAssertFalse(GameExit.crashMarkerInPlayerLog(paths, since: Date().addingTimeInterval(-60)))
    }

    func testFactsFromSnapshot() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        let rt = paths.runtime.path
        let handler = WineProcess(pid: 9, path: rt + "/bin/wine", argv0: #"C:\TapTapGlobal\Apps\231364\UnityCrashHandler64.exe"#)
        let snap = SessionSnapshot(processes: [handler], runtimesDir: paths.runtimesDir.path, wineserverPath: rt + "/bin/wineserver")
        let now = Date()
        let f = GameExit.facts(paths, launched: now.addingTimeInterval(-600), snapshot: snap, now: now)
        XCTAssertEqual(f.runSeconds, 600)
        XCTAssertFalse(f.crashMarker) // a lingering crash handler is not a crash
    }

    func testStartedByCupid() {
        let launch = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(GameExit.startedByCupid(launched: launch, processStart: launch.addingTimeInterval(3)))
        XCTAssertTrue(GameExit.startedByCupid(launched: launch, processStart: launch.addingTimeInterval(-2)))
        XCTAssertFalse(GameExit.startedByCupid(launched: launch, processStart: launch.addingTimeInterval(3600)))
        XCTAssertFalse(GameExit.startedByCupid(launched: nil, processStart: launch))
        XCTAssertTrue(GameExit.startedByCupid(launched: nil, processStart: nil))
        // The live start time of this process is readable and in the past.
        let me = LiveProcesses.startTime(getpid())
        XCTAssertNotNil(me)
        XCTAssertLessThanOrEqual(me!.timeIntervalSinceNow, 0)
    }

    /// Session.stop ends TapTap first and writes its steps to the stop log (a copy of
    /// /bin/sleep named TapTapGlobal.exe stands in; there is no wineserver).
    func testStopEndsTapTapAndLogs() throws {
        let fm = FileManager.default
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        let exe = paths.runtime.appendingPathComponent("lib/wine/TapTapGlobal.exe")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/bin/sleep", toPath: exe.path)
        let p = Process()
        p.executableURL = exe
        p.arguments = ["30"]
        try p.run()
        defer { if p.isRunning { p.terminate() }; p.waitUntilExit() }
        var seen = false
        for _ in 0..<50 where !seen { seen = !SessionSnapshot.take(paths).launcher.isEmpty; if !seen { Thread.sleep(forTimeInterval: 0.1) } }
        XCTAssertTrue(seen)
        let started = Date()
        try Session.stop(paths: paths, log: Logs.stop(paths))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        p.waitUntilExit()
        XCTAssertTrue(SessionSnapshot.take(paths).processes.isEmpty)
        let log = try String(contentsOf: Logs.stop(paths), encoding: .utf8)
        XCTAssertTrue(log.contains("stop: begin; 1 processes: taptapglobal.exe"), log)
        XCTAssertTrue(log.contains("stop: TapTap ended"), log)
        XCTAssertTrue(log.contains("stop: done"), log)
    }
}
