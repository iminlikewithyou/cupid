import XCTest
@testable import HeartportCore

final class LoaderCacheTests: XCTestCase {
    func testRemovesOnlyEntriesWithDanglingLinks() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("loader-cache-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let runtime = temp.appendingPathComponent("runtime/lib/wine/x86_64-unix", isDirectory: true)
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        let ntdll = runtime.appendingPathComponent("ntdll.so")
        try Data("x".utf8).write(to: ntdll)

        let live = temp.appendingPathComponent("winetemp-1-2-3-4", isDirectory: true)
        let stale = temp.appendingPathComponent("winetemp-5-6-7-8", isDirectory: true)
        let noLink = temp.appendingPathComponent("winetemp-9-9-9-9", isDirectory: true)
        let other = temp.appendingPathComponent("something-else", isDirectory: true)
        for dir in [live, stale, noLink, other] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try fm.createSymbolicLink(atPath: live.appendingPathComponent("ntdll.so").path, withDestinationPath: ntdll.path)
        try fm.createSymbolicLink(atPath: stale.appendingPathComponent("ntdll.so").path,
                                  withDestinationPath: temp.appendingPathComponent("moved-away/ntdll.so").path)
        try fm.createSymbolicLink(atPath: other.appendingPathComponent("ntdll.so").path,
                                  withDestinationPath: temp.appendingPathComponent("moved-away/ntdll.so").path)

        let removed = LoaderCache.removeStaleEntries(in: temp)

        XCTAssertEqual(removed, [stale])
        XCTAssertTrue(fm.fileExists(atPath: live.path))
        XCTAssertFalse(fm.fileExists(atPath: stale.path))
        XCTAssertTrue(fm.fileExists(atPath: noLink.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path), "only winetemp-* entries are considered")
    }

    func testDarwinUserTempDirExists() {
        let dir = LoaderCache.darwinUserTempDir()
        XCTAssertNotNil(dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir!.path))
    }
}

/// Programs CrossOver's loader re-executes from `winetemp-*/` are part of the session when the
/// entry's ntdll.so link points into `<data>/runtime/` (copies of /bin/sleep stand in).
final class LoaderCacheSessionTests: XCTestCase {
    func testSnapshotSeesProgramsRunFromTheLoaderCache() throws {
        let fm = FileManager.default
        let root = try tempDir()
        defer { try? fm.removeItem(at: root) }
        let paths = Paths(dataRoot: root.appendingPathComponent("data", isDirectory: true))
        let cache = root.appendingPathComponent("T", isDirectory: true)

        let unixDir = paths.runtime.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        try fm.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: unixDir.appendingPathComponent("ntdll.so"))
        let elsewhere = root.appendingPathComponent("other-runtime/lib/wine/x86_64-unix", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: elsewhere.appendingPathComponent("ntdll.so"))

        let ours = cache.appendingPathComponent("winetemp-1-2-3-4", isDirectory: true)
        let foreign = cache.appendingPathComponent("winetemp-5-6-7-8", isDirectory: true)
        for (dir, target) in [(ours, unixDir), (foreign, elsewhere)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: dir.appendingPathComponent("ntdll.so").path,
                                      withDestinationPath: target.appendingPathComponent("ntdll.so").path)
        }
        let installerExe = ours.appendingPathComponent("TapTap_Global_PC_Setup_x.exe")
        let launcherExe = ours.appendingPathComponent("TapTapGlobal.exe")
        let foreignExe = foreign.appendingPathComponent("TapTapGlobal.exe")
        for exe in [installerExe, launcherExe, foreignExe] { try fm.copyItem(atPath: "/bin/sleep", toPath: exe.path) }

        var running: [Process] = []
        defer { for p in running { p.terminate(); p.waitUntilExit() } }
        for exe in [installerExe, launcherExe, foreignExe] {
            let p = Process()
            p.executableURL = exe
            p.arguments = ["30"]
            try p.run()
            running.append(p)
        }

        var snap = SessionSnapshot.take(paths, loaderCacheDir: cache)
        for _ in 0..<50 where snap.processes.count < 2 {
            Thread.sleep(forTimeInterval: 0.1)
            snap = SessionSnapshot.take(paths, loaderCacheDir: cache)
        }
        XCTAssertEqual(Set(snap.processes.map(\.pid)), [running[0].processIdentifier, running[1].processIdentifier])
        XCTAssertEqual(snap.installer.map(\.pid), [running[0].processIdentifier])
        XCTAssertEqual(snap.launcher.map(\.pid), [running[1].processIdentifier])
        XCTAssertFalse(snap.isAlive, "no wineserver in this fake session")

        // Without the loader cache directory they are invisible (the old behaviour).
        XCTAssertTrue(SessionSnapshot.take(paths, loaderCacheDir: nil).processes.isEmpty)

        // `heartport status` reports them.
        let status = StatusReport.session(from: snap)
        XCTAssertTrue(status.installerRunning)
        XCTAssertTrue(status.launcherRunning)
    }
}
