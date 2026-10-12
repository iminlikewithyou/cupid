import XCTest
@testable import CupidCore

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
        // Full names from the files' name tables (name ID 4), as Wine names registry values.
        XCTAssertEqual(WindowsFonts.all.map(\.registryValue),
                       ["Arial (TrueType)", "Arial Bold (TrueType)", "Arial Italic (TrueType)",
                        "Arial Bold Italic (TrueType)", "Arial Unicode MS (TrueType)"])
    }

    /// system.reg text with every font registered (what `reg.exe add` leaves after the step).
    static func registeredSystemReg(_ links: [WindowsFonts.Link] = WindowsFonts.all) -> String {
        "[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts] 1\n"
            + links.map { "\"\($0.registryValue)\"=\"\($0.name)\"\n" }.joined()
    }

    func testRegistrySeedsFollowTheList() {
        XCTAssertEqual(RegistrySeeds.fonts, WindowsFonts.all.map(\.registrySeed))
        let unicode = WindowsFonts.all.last!.registrySeed
        XCTAssertEqual(unicode.hive, .localMachine)
        XCTAssertEqual(unicode.policy, .whenAbsent)
        XCTAssertEqual(unicode.regAddArguments,
                       ["reg.exe", "add", #"HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts"#,
                        "/v", "Arial Unicode MS (TrueType)", "/t", "REG_SZ", "/d", "Arial Unicode.ttf", "/f"])
        XCTAssertEqual(WindowsFonts.all[0].staleExternalDeleteArguments,
                       ["reg.exe", "delete", #"HKCU\Software\Wine\Fonts\External Fonts"#, "/v", "Arial (TrueType)", "/f"])
        // The HKCU list (Reset graphics) does not include them.
        XCTAssertFalse(RegistrySeeds.all.contains { $0.hive == .localMachine })
    }

    func testRegistrationIsSatisfiedByAnyValue() {
        let seed = WindowsFonts.all[0].registrySeed
        XCTAssertFalse(seed.isSatisfied(by: nil))
        XCTAssertFalse(seed.isSatisfied(by: RegFile(text: "[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts] 1\n\"Arial Black (TrueType)\"=\"Z:\\\\x.ttf\"\n")))
        XCTAssertTrue(seed.isSatisfied(by: RegFile(text: Self.registeredSystemReg())))
        // A value Wine or the player wrote (another path) counts; it is not overwritten.
        XCTAssertTrue(seed.isSatisfied(by: RegFile(text: "[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts] 1\n\"Arial (TrueType)\"=\"Z:\\\\System\\\\Library\\\\Fonts\\\\Supplemental\\\\Arial.ttf\"\n")))
    }

    func testUnregisteredSkipsFontsAbsentFromMacAndPrefix() throws {
        let dir = try tempDir().appendingPathComponent("Fonts")
        let nope = WindowsFonts.Link(name: "Nope.ttf", face: "Nope", source: "/nonexistent/Nope.ttf")
        XCTAssertEqual(WindowsFonts.unregistered(in: dir, systemReg: nil, links: [nope]), [])
        // A file already in windows/Fonts (the player's own) is registered even without a source.
        try write("player's own", to: dir.appendingPathComponent("Nope.ttf"))
        XCTAssertEqual(WindowsFonts.unregistered(in: dir, systemReg: nil, links: [nope]), [nope])
        XCTAssertEqual(WindowsFonts.unregistered(in: dir, systemReg: RegFile(text: Self.registeredSystemReg([nope])), links: [nope]), [])
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
        let values = WindowsFonts.all.map(\.registryValue)
        func nonSeedSteps() -> [PrefixSetup.Step] { setup.plan(state: state).filter { if case .seed = $0 { return false }; return true } }
        XCTAssertEqual(nonSeedSteps(), [.fontLinks(names), .fontRegistry(values)])
        XCTAssertEqual(StatusReport.gather(paths).prefix.missingFonts, names)
        XCTAssertEqual(StatusReport.gather(paths).prefix.unregisteredFonts, values)

        XCTAssertEqual(try WindowsFonts.create(in: paths.windowsFonts).map(\.name), names)
        for link in WindowsFonts.all {
            let dest = paths.windowsFonts.appendingPathComponent(link.name).path
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dest), link.source)
        }
        XCTAssertEqual(WindowsFonts.pending(in: paths.windowsFonts), [])
        XCTAssertEqual(try WindowsFonts.create(in: paths.windowsFonts), [], "idempotent")
        // Linked but not registered: a missing registry value is pending like a missing link.
        XCTAssertEqual(nonSeedSteps(), [.fontRegistry(values)])
        XCTAssertEqual(StatusReport.gather(paths).prefix.missingFonts, [])
        XCTAssertEqual(StatusReport.gather(paths).prefix.unregisteredFonts, values)
        XCTAssertFalse(SetupInputs(StatusReport.gather(paths)).prefixReady)

        try write("[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion] 1\n\"CurrentBuild\"=\"19045\"\n\"ProductName\"=\"Microsoft Windows 10\"\n"
                  + Self.registeredSystemReg(), to: paths.systemReg)
        XCTAssertEqual(nonSeedSteps(), [])
        XCTAssertEqual(StatusReport.gather(paths).prefix.unregisteredFonts, [])
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
        let links = [WindowsFonts.Link(name: "Nope.ttf", face: "Nope", source: "/nonexistent/Nope.ttf")]
        XCTAssertEqual(WindowsFonts.pending(in: dir, links: links), [])
        XCTAssertEqual(try WindowsFonts.create(in: dir, links: links), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
