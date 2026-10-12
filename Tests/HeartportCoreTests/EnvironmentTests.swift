import XCTest
@testable import HeartportCore

final class EnvironmentTests: XCTestCase {
    let paths = Paths(dataRoot: URL(fileURLWithPath: "/Users/p/Library/Application Support/Heartport"))
    var rt: String { "/Users/p/Library/Application Support/Heartport/runtime/phase2-20261007.3" }
    let data = "/Users/p/Library/Application Support/Heartport"

    func testContractValues() {
        let env = LaunchEnvironment.build(paths: paths)
        let expected: [String: String] = [
            "WINEPREFIX": "\(data)/prefix",
            "WINESERVER": "\(rt)/bin/wineserver",
            "WINELOADER": "\(rt)/bin/wine",
            "WINEDLLPATH": "\(rt)/lib/wine",
            "WINEARCH": "win64", "WINEDEBUG": "-all",
            "WINEMSYNC": "1", "WINEESYNC": "0",
            "ROSETTA_ADVERTISE_AVX": "1", "WINE_SIMULATE_WRITECOPY": "1",
            "CX_ACTIVE_GRAPHICS_BACKEND": "dxmt", "CX_GRAPHICS_BACKEND": "dxmt",
            "CX_APPLEGPTK_LIBD3DSHARED_PATH": "\(rt)/lib/external/libd3dshared.dylib",
            "WINEDLLOVERRIDES": "d3d11,dxgi,d3d10core,winemetal=b;d3d12,nvapi64,nvngx=",
            "DXMT_CONFIG_FILE": #"Z:\Users\p\Library\Application Support\Heartport\dxmt.conf"#,
            "DXMT_SHADER_CACHE_PATH": "\(data)/cache/shaders",
            "DXMT_PIPELINE_CACHE_PATH": "\(data)/cache/pipelines",
            "DXMT_PIPELINE_CACHE_NAMESPACE": "heartopia-v1",
            "DXMT_PIPELINE_CACHE_PREWARM_MS": "10000",
            "DXMT_PIPELINE_CACHE_PREWARM_LIMIT": "128",
            "DXMT_PIPELINE_CACHE_PREFER_EXPENSIVE": "1",
            "DXMT_PREPARE_SHADERS": "1", "DXMT_USE_DEFAULT_METAL_CACHE": "1",
            "DXMT_CANVAS_DRAWABLES": "3", "DXMT_CANVAS_OVERLAY": "0",
            "DXMT_METALFX_SPATIAL_SWAPCHAIN": "1",
            "DXMT_LOG_LEVEL": "error", "DXMT_LOG_PATH": "none",
            "WINEMAC_MOUSELOOK": "xdt.exe", "WINE_GAME_MODE": "xdt.exe",
            "WINE_NO_DOCK_ICON": "TapTapGlobal.exe",
            "GST_PLUGIN_SYSTEM_PATH_1_0": "\(rt)/lib/gstreamer-1.0",
            "GST_PLUGIN_PATH_1_0": "\(rt)/lib/gstreamer-1.0",
            "GST_REGISTRY_1_0": "\(data)/cache/gstreamer-registry.bin",
            "GST_REGISTRY_FORK": "no",
            "HOME": "\(data)/home", "USER": "player", "TMPDIR": "\(data)/tmp",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        XCTAssertEqual(env, expected)
        XCTAssertNil(env["MTL_HUD_ENABLED"])
        XCTAssertNil(env["WINEMAC_INPUT_STATS"])
    }

    func testInheritedVariablesAreStripped() {
        let inherited = [
            "CX_ROOT": "/x", "WINEDEBUG": "+all", "WINEPREFIX": "/Users/p/.wine", "WINE_LARGE_ADDRESS_AWARE": "1",
            "DYLD_INSERT_LIBRARIES": "/evil.dylib", "ROSETTA_DEBUG": "1", "MTL_HUD_ENABLED": "1",
            "DXMT_LOG_LEVEL": "trace", "GST_PLUGIN_PATH": "/g", "D3DM_FOO": "1",
            "LANG": "en_US.UTF-8", "HOME": "/Users/p", "TMPDIR": "/var/folders/x", "PATH": "/opt/homebrew/bin:/usr/bin",
        ]
        let env = LaunchEnvironment.build(paths: paths, inherited: inherited)
        for key in ["CX_ROOT", "WINE_LARGE_ADDRESS_AWARE", "DYLD_INSERT_LIBRARIES", "ROSETTA_DEBUG", "MTL_HUD_ENABLED", "GST_PLUGIN_PATH", "D3DM_FOO"] {
            XCTAssertNil(env[key], key)
        }
        XCTAssertEqual(env["WINEDEBUG"], "-all")
        XCTAssertEqual(env["WINEPREFIX"], "\(data)/prefix")
        XCTAssertEqual(env["DXMT_LOG_LEVEL"], "error")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["HOME"], "\(data)/home")
        XCTAssertEqual(env["TMPDIR"], "\(data)/tmp")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertFalse(env.values.contains { $0.contains("/.wine") })
    }

    func testGStreamerUsesOnlyTheRuntimePlugins() {
        let inherited = ["GST_DEBUG": "*:6", "GST_PLUGIN_PATH_1_0": "/opt/homebrew/lib/gstreamer-1.0",
                         "GST_PLUGIN_SCANNER_1_0": "/opt/homebrew/libexec/gst-plugin-scanner", "GST_REGISTRY": "/tmp/r.bin"]
        let env = LaunchEnvironment.build(paths: paths, inherited: inherited)
        XCTAssertNil(env["GST_DEBUG"])
        XCTAssertNil(env["GST_PLUGIN_SCANNER_1_0"])
        XCTAssertNil(env["GST_REGISTRY"])
        XCTAssertEqual(env["GST_PLUGIN_PATH_1_0"], "\(rt)/lib/gstreamer-1.0")
        XCTAssertEqual(env["GST_PLUGIN_SYSTEM_PATH_1_0"], paths.gstreamerPlugins.path)
        XCTAssertEqual(env["GST_REGISTRY_1_0"], paths.gstreamerRegistry.path)
        XCTAssertEqual(env["GST_REGISTRY_FORK"], "no")
        // Wine's Media Foundation decoders live in winegstreamer: never disabled.
        XCTAssertFalse(env["WINEDLLOVERRIDES"]!.contains("winegstreamer"))
    }

    func testOptions() {
        let stats = URL(fileURLWithPath: "\(data)/logs/input-stats")
        let env = LaunchEnvironment.build(paths: paths, options: .init(hud: true, dxmtInfoLog: true, wineDebug: "err+all,+seh", inputStatsPrefix: stats))
        XCTAssertEqual(env["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env["MTL_HUD_DISABLE_MENU_BAR"], "1")
        XCTAssertEqual(env["MTL_HUD_ELEMENTS"], "device,rosetta,layersize,memory,gamemode,fps,gputime,frameinterval,frameintervalgraph,shaders")
        XCTAssertEqual(env["DXMT_LOG_LEVEL"], "info")
        XCTAssertNil(env["DXMT_LOG_PATH"])
        XCTAssertEqual(env["WINEDEBUG"], "err+all,+seh")
        XCTAssertEqual(env["WINEMAC_INPUT_STATS"], stats.path)
    }

    func testWineIsAlwaysGivenTheContract() {
        let wine = Wine(paths: paths, inherited: ["WINEPREFIX": "/Users/p/.wine"])
        XCTAssertEqual(wine.environment["WINEPREFIX"], "\(data)/prefix")
    }

    func testGameLaunchArguments() {
        XCTAssertEqual(GameLauncher.wineArguments, ["start.exe", "/exec", #"C:\TapTapGlobal\Apps\231364\xdt.exe"#])
        XCTAssertEqual(TapTapLauncher.arguments, [#"C:\Program Files\TapTapGlobal\TapTapGlobal.exe"#,
            "--disable-gpu", "--disable-gpu-compositing", "--in-process-gpu", "--use-gl=angle", "--use-angle=swiftshader", "--launch-context=startup"])
    }

    func testDxmtTemplateMatchesResourceFile() throws {
        let file = try String(contentsOf: repoRoot.appendingPathComponent("Resources/config/dxmt.conf"), encoding: .utf8)
        XCTAssertEqual(DxmtConfig.template, file)
        XCTAssertTrue(DxmtConfig.template.hasPrefix("[xdt.exe]\n"))
        XCTAssertFalse(DxmtConfig.template.contains("nativeFullscreen"))
        XCTAssertFalse(DxmtConfig.template.contains("fullscreenCanvas"))
    }

    func testDxmtWriteOnlyWhenDifferent() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("dxmt.conf")
        XCTAssertTrue(try DxmtConfig.write(to: url))
        XCTAssertFalse(try DxmtConfig.write(to: url))
        XCTAssertTrue(DxmtConfig.isCurrent(at: url))
        XCTAssertTrue(DxmtConfig.template.contains("d3d11.preferredMaxFrameRate = 60\n"))
        // An install from before the 60 fps cap is rewritten on its next play.
        try write(DxmtConfig.template.replacingOccurrences(of: "preferredMaxFrameRate = 60", with: "preferredMaxFrameRate = 120"), to: url)
        XCTAssertFalse(DxmtConfig.isCurrent(at: url))
        XCTAssertTrue(try DxmtConfig.write(to: url))
        XCTAssertTrue(DxmtConfig.isCurrent(at: url))
        try write("[xdt.exe]\nold\n", to: url)
        XCTAssertFalse(DxmtConfig.isCurrent(at: url))
        XCTAssertTrue(try DxmtConfig.write(to: url))
    }
}
