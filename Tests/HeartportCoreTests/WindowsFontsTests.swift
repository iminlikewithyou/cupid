import XCTest
@testable import HeartportCore

final class WindowsFontsTests: XCTestCase {
    func requireSources() throws {
        for link in WindowsFonts.all where !FileManager.default.fileExists(atPath: link.source) {
            throw XCTSkip("\(link.source) is not on this Mac")
        }
    }

    func testListIsArialFromSupplemental() {
        XCTAssertEqual(WindowsFonts.all.map(\.name),
                       ["Arial.ttf", "Arial Bold.ttf", "Arial Italic.ttf", "Arial Bold Italic.ttf", "Arial Unicode.ttf"])
        XCTAssertTrue(WindowsFonts.all.allSatisfy { $0.source == "/System/Library/Fonts/Supplemental/\($0.name)" })
    }

    func testCreatesLinksOnceAndPlanSeesThem() throws {
        try requireSources()
        let paths = Paths(dataRoot: try tempDir())
        let setup = PrefixSetup(paths: paths)
        // Existing, otherwise complete prefix: only the font step is pending.
        try write("[Software\\\\Wine\\\\Mac Driver] 1\n\"RetinaMode\"=\"N\"\n[Software\\\\xd\\\\Heartopia] 1\n\"UnityGraphicsQuality_h1669003810\"=dword:00000001\n", to: paths.userReg)
        try write("[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion] 1\n\"CurrentBuild\"=\"19045\"\n\"ProductName\"=\"Microsoft Windows 10\"\n", to: paths.systemReg)
        try FileManager.default.createDirectory(at: paths.driveC, withIntermediateDirectories: true)
        var state = AppState(); state.runtime = paths.runtimeVersion
        let names = WindowsFonts.all.map(\.name)
        XCTAssertEqual(setup.plan(state: state).filter { if case .seed = $0 { return false }; return true }, [.fontLinks(names)])
        XCTAssertEqual(StatusReport.gather(paths).prefix.missingFonts, names)

        XCTAssertEqual(try WindowsFonts.create(in: paths.windowsFonts).map(\.name), names)
        for link in WindowsFonts.all {
            let dest = paths.windowsFonts.appendingPathComponent(link.name).path
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dest), link.source)
        }
        XCTAssertEqual(WindowsFonts.pending(in: paths.windowsFonts), [])
        XCTAssertEqual(try WindowsFonts.create(in: paths.windowsFonts), [], "idempotent")
        XCTAssertFalse(setup.plan(state: state).contains { if case .fontLinks = $0 { return true }; return false })
        XCTAssertEqual(StatusReport.gather(paths).prefix.missingFonts, [])
    }

    func testKeepsExistingFileAndReplacesDanglingLink() throws {
        try requireSources()
        let dir = try tempDir().appendingPathComponent("Fonts")
        try write("player's own", to: dir.appendingPathComponent("Arial.ttf"))
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("Arial Bold.ttf").path, withDestinationPath: "/nonexistent/Arial Bold.ttf")
        XCTAssertEqual(WindowsFonts.pending(in: dir).map(\.name), ["Arial Bold.ttf", "Arial Italic.ttf", "Arial Bold Italic.ttf", "Arial Unicode.ttf"])
        try WindowsFonts.create(in: dir)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Arial.ttf"), encoding: .utf8), "player's own")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("Arial Bold.ttf").path),
                       "/System/Library/Fonts/Supplemental/Arial Bold.ttf")
    }

    func testMissingSourceIsSkipped() throws {
        let dir = try tempDir().appendingPathComponent("Fonts")
        let links = [WindowsFonts.Link(name: "Nope.ttf", source: "/nonexistent/Nope.ttf")]
        XCTAssertEqual(WindowsFonts.pending(in: dir, links: links), [])
        XCTAssertEqual(try WindowsFonts.create(in: dir, links: links), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
