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
