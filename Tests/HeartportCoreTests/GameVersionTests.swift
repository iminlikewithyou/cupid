import Foundation
import XCTest
@testable import HeartportCore

final class GameVersionTests: XCTestCase {
    func testReadsVersionAndBuild() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        XCTAssertNil(GameVersion.read(paths))
        XCTAssertTrue(paths.gameVersionFile.path.hasSuffix(
            "prefix/drive_c/TapTapGlobal/Apps/231364/xdt_Data/StreamingAssets/version.xdtconf"))
        // As shipped: CRLF line ends, extra fields.
        let text = "{\r\n  \"Branch\": \"obt_release5\",\r\n  \"Version\": \"0.5.5\",\r\n  \"MajorVersion\": \"5847751\",\r\n"
            + "  \"MonoVersion\": \"5847751\",\r\n  \"ResVersion\": \"5847751\",\r\n  \"UseTapUpdate\": \"1\"\r\n}"
        try write(text, to: paths.gameVersionFile)
        XCTAssertEqual(GameVersion.read(paths),
                       GameVersion(version: "0.5.5", build: "5847751", branch: "obt_release5", resVersion: "5847751"))
        let report = StatusReport.gather(paths)
        XCTAssertEqual(report.game.version, "0.5.5")
        XCTAssertEqual(report.game.build, "5847751")
    }

    func testBOMAndMissingFields() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("version.xdtconf")
        try Data([0xEF, 0xBB, 0xBF] + Array(#"{"Version":"1.0.0"}"#.utf8)).write(to: file)
        XCTAssertEqual(GameVersion.read(file: file), GameVersion(version: "1.0.0"))
        try write(#"{"Branch":"x","Version":"  "}"#, to: file)
        XCTAssertNil(GameVersion.read(file: file))
        try write("not json", to: file)
        XCTAssertNil(GameVersion.read(file: file))
    }
}
