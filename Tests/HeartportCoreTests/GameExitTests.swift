import XCTest
@testable import HeartportCore

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
}
