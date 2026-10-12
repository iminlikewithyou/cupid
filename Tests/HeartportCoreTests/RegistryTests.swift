import XCTest
@testable import HeartportCore

final class RegistryTests: XCTestCase {
    func testSeedListIsExactlyPhase2() {
        let expected: [(String, UInt32)] = [
            ("UnityGraphicsQuality_h1669003810", 1),
            ("QualityLevel_h4026849054", 1),
            ("NewUserGraphicsQualityString_h2322609765", 1),
            ("ORIGIN_QUALITY_h3319388771", 1),
            ("RenderScaleString_h868707778", 2),
            ("ShaderQualityString_h3156345780", 1),
            ("FXAAEnabledString_h219820651", 0),
            ("BloomEnabledString_h1769754614", 1),
            ("PcUICanvasScale_h3623448666", 1),
            ("SoundVolumeString_h3855669083", 25),
            ("SoundEffectVolume_h2094452281", 50),
            ("Screenmanager Fullscreen mode_h3630240806", 1),
        ]
        XCTAssertEqual(RegistrySeeds.gamePrefs.count, expected.count)
        for (seed, (name, value)) in zip(RegistrySeeds.gamePrefs, expected) {
            XCTAssertEqual(seed.key, #"Software\xd\Heartopia"#)
            XCTAssertEqual(seed.name, name)
            XCTAssertEqual(seed.value, .dword(value))
            XCTAssertEqual(seed.policy, .whenAbsent)
        }
        XCTAssertEqual(RegistrySeeds.retinaMode.key, #"Software\Wine\Mac Driver"#)
        XCTAssertEqual(RegistrySeeds.retinaMode.value, .string("N"))
        XCTAssertEqual(RegistrySeeds.all.count, 13)
        // No resolution or screen-size seeds (they caused the first-launch "Apply?" prompt).
        XCTAssertFalse(RegistrySeeds.all.contains { $0.name.contains("Resolution") })
    }

    func testRegAddArguments() {
        XCTAssertEqual(RegistrySeeds.retinaMode.regAddArguments,
                       ["reg.exe", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ", "/d", "N", "/f"])
        let fullscreen = RegistrySeeds.gamePrefs.last!
        XCTAssertEqual(fullscreen.regAddArguments,
                       ["reg.exe", "add", #"HKCU\Software\xd\Heartopia"#, "/v", "Screenmanager Fullscreen mode_h3630240806", "/t", "REG_DWORD", "/d", "1", "/f"])
    }

    static let userReg = #"""
    WINE REGISTRY Version 2
    ;; All keys relative to REGISTRY\\User\\S-1-5-21-0-0-0-1000

    #arch=win64

    [Software\\Wine\\Mac Driver] 1791756279
    #time=1dd59cc8327060e
    "RetinaMode"="Y"

    [Software\\xd\\Heartopia] 1791756825
    #time=1dd59cdc84196a4
    "305634954670guideCompele1_h1760444285"=dword:00000001
    "BloomEnabledString_h1769754614"=dword:00000001
    "FXAAEnabledString_h219820651"=dword:00000000
    "LastPcResolutionLevelStringV1_h1546529270"=dword:00000008
    "NewUserGraphicsQualityString_h2322609765"=dword:00000003
    "ORIGIN_QUALITY_h3319388771"=dword:00000003
    "PcResolutionLevelString_h3084135899"=dword:0000000c
    "PcUICanvasScale_h3623448666"=dword:00000001
    "QualityLevel_h4026849054"=dword:00000001
    "RenderScaleString_h868707778"=dword:00000001
    "Screenmanager Fullscreen mode_h3630240806"=dword:00000001
    "Screenmanager Resolution Height_h2627697771"=dword:00000438
    "Screenmanager Resolution Use Native_h1405027254"=dword:00000000
    "Screenmanager Resolution Width_h182942802"=dword:00000780
    "ShaderQualityString_h3156345780"=dword:00000001
    "SoundEffectVolume_h2094452281"=dword:00000032
    "SoundVolumeString_h3855669083"=dword:00000019
    "SCHEME_PROFILE_h4026564772"=hex:53,74,61,6e,00
    "Quote \"name\" with \\ slash"="v\\al"

    """#

    func testParseUserReg() {
        let reg = RegFile(text: Self.userReg)
        XCTAssertTrue(reg.hasKey(#"Software\xd\Heartopia"#))
        XCTAssertTrue(reg.hasKey(#"software\XD\heartopia"#))
        XCTAssertEqual(reg.string(#"Software\Wine\Mac Driver"#, "RetinaMode"), "Y")
        XCTAssertEqual(reg.dword(#"Software\xd\Heartopia"#, "PcResolutionLevelString_h3084135899"), 12)
        XCTAssertEqual(reg.dword(#"Software\xd\Heartopia"#, "screenmanager fullscreen mode_h3630240806"), 1)
        XCTAssertEqual(reg.string(#"Software\xd\Heartopia"#, #"Quote "name" with \ slash"#), #"v\al"#)
        XCTAssertNil(reg.dword(#"Software\xd\Heartopia"#, "SCHEME_PROFILE_h4026564772"))
    }

    func testPendingSeedsKeepPlayerChoices() {
        let reg = RegFile(text: Self.userReg)
        let pending = RegistrySeeds.pending(in: reg)
        // RetinaMode=Y is enforced to N; only the absent UnityGraphicsQuality is added; values the
        // player changed (NewUserGraphicsQuality=3, LastPcResolution=8, RenderScale=1) are kept.
        XCTAssertEqual(pending.map(\.name), ["RetinaMode", "UnityGraphicsQuality_h1669003810"])
        XCTAssertEqual(RegistrySeeds.pending(in: reg, force: true).count, 13)
        XCTAssertEqual(RegistrySeeds.pending(in: nil).count, 13)
        let fixed = RegFile(text: Self.userReg.replacingOccurrences(of: #""RetinaMode"="Y""#, with: #""RetinaMode"="N""#)
                            + "\n[Software\\\\xd\\\\Heartopia] 1\n\"UnityGraphicsQuality_h1669003810\"=dword:00000003\n")
        XCTAssertEqual(RegistrySeeds.pending(in: fixed), [])
    }

    func testWindows10Detection() {
        let system = RegFile(text: #"""
        [Software\\Microsoft\\Windows NT\\CurrentVersion] 1
        "CurrentBuild"="19045"
        "ProductName"="Microsoft Windows 10"
        """#)
        XCTAssertTrue(RegistrySeeds.isWindows10(system))
        XCTAssertFalse(RegistrySeeds.isWindows10(RegFile(text: "[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion] 1\n\"ProductName\"=\"Microsoft Windows 7\"\n")))
        XCTAssertFalse(RegistrySeeds.isWindows10(nil))
    }

    func testPrefixPlan() throws {
        let root = try tempDir()
        let paths = Paths(dataRoot: root)
        let setup = PrefixSetup(paths: paths)
        var state = AppState()
        XCTAssertEqual(setup.plan(state: state).first, .wineboot(reason: "create"))
        XCTAssertTrue(setup.plan(state: state).contains(.winecfgWin10))

        try write(Self.userReg.replacingOccurrences(of: #""RetinaMode"="Y""#, with: #""RetinaMode"="N""#)
                  + "\n[Software\\\\xd\\\\Heartopia] 1\n\"UnityGraphicsQuality_h1669003810\"=dword:00000001\n", to: paths.userReg)
        try write("[Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion] 1\n\"CurrentBuild\"=\"19045\"\n\"ProductName\"=\"Microsoft Windows 10\"\n", to: paths.systemReg)
        try FileManager.default.createDirectory(at: paths.usersDir.appendingPathComponent("crossover/Documents"), withIntermediateDirectories: true)
        state.runtime = paths.runtimeVersion
        XCTAssertEqual(setup.plan(state: state), [])

        try FileManager.default.createSymbolicLink(atPath: paths.usersDir.appendingPathComponent("crossover/Desktop").path, withDestinationPath: "/Users/p/Desktop")
        XCTAssertEqual(setup.userLinks(), ["crossover/Desktop"])
        XCTAssertEqual(setup.plan(state: state), [.replaceLinks(["crossover/Desktop"])])

        state.prefixRuntime = "phase2-older"
        XCTAssertEqual(setup.plan(state: state).first, .wineboot(reason: "runtime changed from phase2-older"))
    }
}
