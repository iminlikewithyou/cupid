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

/// Every location Mactopia uses. The data root defaults to
/// `~/Library/Application Support/Mactopia` and may be overridden (tests, `--data`, `MACTOPIA_DATA` or its alias `MACTOPIA_DATA_ROOT`).
public struct Paths: Sendable, Equatable {
    /// Recall 1.3.0's runtime version (runtime.json "version").
    public static let defaultRuntimeVersion = "phase2-20261007.3"

    public let dataRoot: URL
    public let runtimeVersion: String

    public init(dataRoot: URL, runtimeVersion: String = Paths.defaultRuntimeVersion) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.runtimeVersion = runtimeVersion
    }

    /// `MACTOPIA_DATA` (or `MACTOPIA_DATA_ROOT`) if set, else `~/Library/Application Support/Mactopia` of the real user
    /// (the account's home directory, not `$HOME`, which Wine children override).
    public static func resolve(dataOverride: String? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               userHome: URL = Paths.accountHome()) -> Paths {
        let fromEnv = [environment["MACTOPIA_DATA"], environment["MACTOPIA_DATA_ROOT"]].compactMap { $0 }.first { !$0.isEmpty }
        if let override = dataOverride ?? fromEnv, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return Paths(dataRoot: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return Paths(dataRoot: userHome.appendingPathComponent("Library/Application Support/Mactopia", isDirectory: true))
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
    public var launcherDir: URL { driveC.appendingPathComponent("Program Files/TapTapGlobal", isDirectory: true) }
    public var launcherExe: URL { launcherDir.appendingPathComponent(Game.launcherExeName) }
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
