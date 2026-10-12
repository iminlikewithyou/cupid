import Foundation

/// The launch contract (docs/PHASE2.md "Launch contract"): the environment of every Wine process.
public enum LaunchEnvironment {
    public struct Options: Sendable, Equatable {
        /// Metal performance HUD.
        public var hud: Bool
        /// DXMT at info level, logging to the process's stdout (first launch only by default).
        public var dxmtInfoLog: Bool
        /// Overrides WINEDEBUG (`-all` by default), e.g. `err+all,+seh` to diagnose a crash.
        public var wineDebug: String?
        /// `WINEMAC_INPUT_STATS` file prefix; the driver writes `<prefix>-<pid>.jsonl`.
        public var inputStatsPrefix: URL?

        public init(hud: Bool = false, dxmtInfoLog: Bool = false, wineDebug: String? = nil, inputStatsPrefix: URL? = nil) {
            self.hud = hud
            self.dxmtInfoLog = dxmtInfoLog
            self.wineDebug = wineDebug
            self.inputStatsPrefix = inputStatsPrefix
        }
    }

    /// Inherited variables with these prefixes change Wine, Rosetta or renderer behaviour and
    /// are removed. `D3DM_` (D3DMetal) is the spike's addition to PHASE2's list.
    public static let strippedPrefixes = ["CX_", "WINE", "DYLD_", "ROSETTA_", "MTL_", "DXMT_", "GST_", "D3DM_"]

    public static let dllOverrides = "d3d11,dxgi,d3d10core,winemetal=b;d3d12,nvapi64,nvngx="
    public static let hudElements = "device,rosetta,layersize,memory,gamemode,fps,gputime,frameinterval,frameintervalgraph,shaders"
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Pure: the full environment for a Wine process.
    public static func build(paths: Paths, options: Options = Options(),
                             inherited: [String: String] = [:]) -> [String: String] {
        var env = inherited.filter { key, _ in !strippedPrefixes.contains { key.hasPrefix($0) } }
        let contract: [String: String] = [
            "PATH": path,
            "WINEPREFIX": paths.prefix.path,
            "WINESERVER": paths.wineserver.path,
            "WINELOADER": paths.wine.path,
            "WINEDLLPATH": paths.wineDLLPath.path,
            "WINEARCH": "win64",
            "WINEDEBUG": options.wineDebug ?? "-all",
            "WINEMSYNC": "1",
            "WINEESYNC": "0",
            "ROSETTA_ADVERTISE_AVX": "1",
            "WINE_SIMULATE_WRITECOPY": "1",
            "CX_ACTIVE_GRAPHICS_BACKEND": "dxmt",
            "CX_GRAPHICS_BACKEND": "dxmt",
            "CX_APPLEGPTK_LIBD3DSHARED_PATH": paths.libD3DShared.path,
            "WINEDLLOVERRIDES": dllOverrides,
            "DXMT_CONFIG_FILE": Paths.windowsPath(paths.dxmtConf),
            "DXMT_SHADER_CACHE_PATH": paths.shaderCache.path,
            "DXMT_PIPELINE_CACHE_PATH": paths.pipelineCache.path,
            "DXMT_PIPELINE_CACHE_NAMESPACE": Game.pipelineNamespace,
            "DXMT_PIPELINE_CACHE_PREWARM_MS": "10000",
            "DXMT_PIPELINE_CACHE_PREWARM_LIMIT": "128",
            "DXMT_PIPELINE_CACHE_PREFER_EXPENSIVE": "1",
            "DXMT_PREPARE_SHADERS": "1",
            "DXMT_USE_DEFAULT_METAL_CACHE": "1",
            "DXMT_CANVAS_DRAWABLES": "3",
            "DXMT_CANVAS_OVERLAY": "0",
            "DXMT_METALFX_SPATIAL_SWAPCHAIN": "1",
            "DXMT_LOG_LEVEL": "error",
            "DXMT_LOG_PATH": "none",
            "WINEMAC_MOUSELOOK": Game.exeName,
            "WINE_GAME_MODE": Game.exeName,
            "WINE_NO_DOCK_ICON": Game.launcherExeName,
            "HOME": paths.home.path,
            "USER": "player",
            "TMPDIR": paths.tmp.path,
        ]
        env.merge(contract) { _, new in new }
        if options.dxmtInfoLog {
            env["DXMT_LOG_LEVEL"] = "info"
            env.removeValue(forKey: "DXMT_LOG_PATH")
        }
        if options.hud {
            env["MTL_HUD_ENABLED"] = "1"
            env["MTL_HUD_DISABLE_MENU_BAR"] = "1"
            env["MTL_HUD_ELEMENTS"] = hudElements
        }
        if let stats = options.inputStatsPrefix {
            env["WINEMAC_INPUT_STATS"] = stats.path
        }
        return env
    }
}
