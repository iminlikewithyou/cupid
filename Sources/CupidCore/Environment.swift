import Foundation

/// How the game's fullscreen window sits on the Mac (Settings "Fullscreen").
public enum FullscreenMode: String, CaseIterable, Sendable, Codable {
    /// Covers the whole panel, beside the camera too, above notification banners.
    case fill
    /// Covers the whole panel at the normal window level: notification banners appear over it
    /// (WINEMAC_FULLSCREEN_NORMAL_LEVEL). The default.
    case fillNotifications
    /// Its own fullscreen Space, like a Mac game (WINEMAC_NATIVE_FULLSCREEN).
    case space

    /// The `play --fullscreen` argument values.
    public init?(argument: String) {
        switch argument {
        case "fill": self = .fill
        case "notifications", "fillNotifications": self = .fillNotifications
        case "space": self = .space
        default: return nil
        }
    }
}

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
        /// The "Fullscreen" setting: `.space` sets WINEMAC_NATIVE_FULLSCREEN,
        /// `.fillNotifications` WINEMAC_FULLSCREEN_NORMAL_LEVEL, `.fill` neither.
        public var fullscreen: FullscreenMode

        public init(hud: Bool = false, dxmtInfoLog: Bool = false, wineDebug: String? = nil, inputStatsPrefix: URL? = nil,
                    fullscreen: FullscreenMode = .fillNotifications) {
            self.hud = hud
            self.dxmtInfoLog = dxmtInfoLog
            self.wineDebug = wineDebug
            self.inputStatsPrefix = inputStatsPrefix
            self.fullscreen = fullscreen
        }
    }

    /// Inherited variables with these prefixes change Wine, Rosetta or renderer behaviour and
    /// are removed. `D3DM_` (D3DMetal) is the spike's addition to PHASE2's list.
    public static let strippedPrefixes = ["CX_", "WINE", "DYLD_", "ROSETTA_", "MTL_", "DXMT_", "GST_", "D3DM_"]

    public static let dllOverrides = "d3d11,dxgi,d3d10core,winemetal=b;d3d12,nvapi64,nvngx="
    public static let hudElements = "device,rosetta,layersize,memory,gamemode,fps,gputime,frameinterval,frameintervalgraph,shaders"
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The Dock name of the game (WINEMAC_APP_NAME, Cupid's Mac driver patch).
    public static let appName = "Heartopia"

    /// The full environment for a Wine process. Pure apart from one file check: the Dock icon
    /// (`WINEMAC_APP_ICON`) is set only when the Game Mode bundle's icon exists.
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
            // Cupid's Mac driver patches (cupid-20261012.4 on; ignored by older runtimes):
            // the Dock shows "Heartopia" (and the icon below) instead of "xdt" and the exe's icon.
            // The "Fullscreen" setting (below): WINEMAC_NATIVE_FULLSCREEN gives the game's
            // fullscreen window its own fullscreen Space; WINEMAC_FULLSCREEN_NORMAL_LEVEL keeps it
            // covering the panel but at the normal window level, under notification banners.
            "WINEMAC_APP_NAME": appName,
            // GStreamer (winegstreamer's Media Foundation decoders): only the runtime's own
            // plugins, a registry in the data folder, and in-process plugin scanning (no
            // gst-plugin-scanner is shipped). GST_DEBUG stays unset (GST_ is stripped above).
            "GST_PLUGIN_SYSTEM_PATH_1_0": paths.gstreamerPlugins.path,
            "GST_PLUGIN_PATH_1_0": paths.gstreamerPlugins.path,
            "GST_REGISTRY_1_0": paths.gstreamerRegistry.path,
            "GST_REGISTRY_FORK": "no",
            "HOME": paths.home.path,
            "USER": "player",
            "TMPDIR": paths.tmp.path,
        ]
        env.merge(contract) { _, new in new }
        let icon = paths.gameModeApp.appendingPathComponent(GameModeBundle.iconFile)
        if FileManager.default.fileExists(atPath: icon.path) {
            env["WINEMAC_APP_ICON"] = icon.path
        }
        if options.dxmtInfoLog {
            env["DXMT_LOG_LEVEL"] = "info"
            env.removeValue(forKey: "DXMT_LOG_PATH")
        }
        if options.hud {
            env["MTL_HUD_ENABLED"] = "1"
            env["MTL_HUD_DISABLE_MENU_BAR"] = "1"
            env["MTL_HUD_ELEMENTS"] = hudElements
        }
        switch options.fullscreen {
        case .fill: break
        case .fillNotifications: env["WINEMAC_FULLSCREEN_NORMAL_LEVEL"] = Game.exeName
        case .space: env["WINEMAC_NATIVE_FULLSCREEN"] = Game.exeName
        }
        if let stats = options.inputStatsPrefix {
            env["WINEMAC_INPUT_STATS"] = stats.path
        }
        return env
    }
}
