import Foundation

/// Fixed facts about the game and its TapTap distribution (docs/PHASE2.md).
public enum Game {
    public static let exeName = "xdt.exe"
    public static let appID = "231364"
    public static let windowsDir = #"C:\TapTapGlobal\Apps\231364"#
    public static let windowsExe = #"C:\TapTapGlobal\Apps\231364\xdt.exe"#
    public static let windowTitle = "Heartopia"
    public static let pipelineNamespace = "heartopia-v1"
    public static let launcherExeName = "TapTapGlobal.exe"
    public static let launcherWindowsExe = #"C:\Program Files\TapTapGlobal\TapTapGlobal.exe"#
    /// Without these the Electron window is blank (DXMT: cross-process swapchain not supported).
    public static let launcherFlags = [
        "--disable-gpu", "--disable-gpu-compositing", "--in-process-gpu",
        "--use-gl=angle", "--use-angle=swiftshader", "--launch-context=startup",
    ]
}

/// Every location Heartport uses. The data root defaults to
/// `~/Library/Application Support/Heartport` and may be overridden (tests, `--data`,
/// `HEARTPORT_DATA_ROOT`).
public struct Paths: Sendable, Equatable {
    /// The runtime version this process installs and uses (runtime.json "version"): Recall 1.3.0's,
    /// or that of a bundled archive's `runtime-archive.json` (`RuntimeArchiveDescriptor.current`).
    public static var defaultRuntimeVersion: String { RuntimeArchiveDescriptor.current.version }

    /// Environment variables that override the data root, in priority order.
    public static let dataRootVariables = ["HEARTPORT_DATA_ROOT"]

    public let dataRoot: URL
    public let runtimeVersion: String

    public init(dataRoot: URL, runtimeVersion: String = Paths.defaultRuntimeVersion) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.runtimeVersion = runtimeVersion
    }

    /// The first non-empty override variable and its value.
    public static func environmentOverride(_ environment: [String: String]) -> (name: String, value: String)? {
        for name in dataRootVariables {
            if let value = environment[name], !value.isEmpty { return (name, value) }
        }
        return nil
    }

    /// `~/Library/Application Support/Heartport` of the real user.
    public static func defaultDataRoot(userHome: URL = Paths.accountHome()) -> URL {
        userHome.appendingPathComponent("Library/Application Support/Heartport", isDirectory: true)
    }

    /// `--data`, else an override variable, else the default root of the real user (the
    /// account's home directory, not `$HOME`, which Wine children override).
    public static func resolve(dataOverride: String? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               userHome: URL = Paths.accountHome()) -> Paths {
        if let override = dataOverride ?? environmentOverride(environment)?.value, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return Paths(dataRoot: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return Paths(dataRoot: defaultDataRoot(userHome: userHome))
    }

    public static func accountHome() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: runtime
    public var runtimesDir: URL { dataRoot.appendingPathComponent("runtime", isDirectory: true) }
    public var runtime: URL { runtimesDir.appendingPathComponent(runtimeVersion, isDirectory: true) }
    public var runtimeManifest: URL { runtime.appendingPathComponent("runtime.json") }
    public var wine: URL { runtime.appendingPathComponent("bin/wine") }
    public var wineserver: URL { runtime.appendingPathComponent("bin/wineserver") }
    public var wineDLLPath: URL { runtime.appendingPathComponent("lib/wine", isDirectory: true) }
    public var wineLoader64: URL { runtime.appendingPathComponent("lib/wine/x86_64-unix/wine") }
    public var libD3DShared: URL { runtime.appendingPathComponent("lib/external/libd3dshared.dylib") }
    public var gameModeApp: URL { runtime.appendingPathComponent(GameModeBundle.relativePath, isDirectory: true) }

    // MARK: data root
    public var prefix: URL { dataRoot.appendingPathComponent("prefix", isDirectory: true) }
    public var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }
    public var userReg: URL { prefix.appendingPathComponent("user.reg") }
    public var systemReg: URL { prefix.appendingPathComponent("system.reg") }
    public var shaderCache: URL { dataRoot.appendingPathComponent("cache/shaders", isDirectory: true) }
    public var pipelineCache: URL { dataRoot.appendingPathComponent("cache/pipelines", isDirectory: true) }
    /// GStreamer plugins of a runtime that ships them (Heartport builds from heartport-20261012.3).
    public var gstreamerPlugins: URL { runtime.appendingPathComponent("lib/gstreamer-1.0", isDirectory: true) }
    /// GStreamer's plugin registry (rebuilt by GStreamer when the plugins change).
    public var gstreamerRegistry: URL { dataRoot.appendingPathComponent("cache/gstreamer-registry.bin") }
    public var home: URL { dataRoot.appendingPathComponent("home", isDirectory: true) }
    public var tmp: URL { dataRoot.appendingPathComponent("tmp", isDirectory: true) }
    public var logs: URL { dataRoot.appendingPathComponent("logs", isDirectory: true) }
    public var downloads: URL { dataRoot.appendingPathComponent("downloads", isDirectory: true) }
    public var dxmtConf: URL { dataRoot.appendingPathComponent("dxmt.conf") }
    public var stateFile: URL { dataRoot.appendingPathComponent("state.json") }

    // MARK: inside the prefix
    public var gameDir: URL { driveC.appendingPathComponent("TapTapGlobal/Apps/\(Game.appID)", isDirectory: true) }
    public var gameExe: URL { gameDir.appendingPathComponent(Game.exeName) }
    public var gameFileInfo: URL { gameDir.appendingPathComponent("GameFileInfo.json") }
    /// The game's version file (GameVersion).
    public var gameVersionFile: URL { gameDir.appendingPathComponent("xdt_Data/StreamingAssets/version.xdtconf") }
    public var launcherDir: URL { driveC.appendingPathComponent("Program Files/TapTapGlobal", isDirectory: true) }
    public var launcherExe: URL { launcherDir.appendingPathComponent(Game.launcherExeName) }
    /// `C:\windows\Fonts` (WindowsFonts links macOS fonts here).
    public var windowsFonts: URL { driveC.appendingPathComponent("windows/Fonts", isDirectory: true) }
    public var usersDir: URL { driveC.appendingPathComponent("users", isDirectory: true) }

    /// Directories created up front (the spike's `mt_dirs`).
    public var layoutDirectories: [URL] {
        [runtimesDir, prefix, shaderCache, pipelineCache, home, tmp, logs, downloads]
    }

    public func createLayout() throws {
        for dir in layoutDirectories {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// `Z:\...` path of a Unix path through Wine's Z: drive.
    public static func windowsPath(_ url: URL) -> String {
        "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
    }
}
