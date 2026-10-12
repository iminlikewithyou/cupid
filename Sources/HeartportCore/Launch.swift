import Foundation

/// Starts Heartopia (docs/PHASE2.md "Launch contract").
public struct GameLauncher: Sendable {
    public struct Options: Sendable {
        public var hud: Bool
        /// nil: info level on the first launch only (marker logs/.dxmt-info-done).
        public var dxmtInfoLog: Bool?
        public var wineDebug: String?
        public var inputStats: Bool
        public var windowTimeout: TimeInterval
        public init(hud: Bool = false, dxmtInfoLog: Bool? = nil, wineDebug: String? = nil,
                    inputStats: Bool = false, windowTimeout: TimeInterval = 120) {
            self.hud = hud; self.dxmtInfoLog = dxmtInfoLog; self.wineDebug = wineDebug
            self.inputStats = inputStats; self.windowTimeout = windowTimeout
        }
    }

    public struct Result: Sendable {
        public let winePID: Int32
        public let game: WineProcess?
        public let window: WindowInfo?
        public let log: URL
        /// The game runs from the Game Mode bundle (it was created through CreateProcess).
        public var inGameModeBundle: Bool { game?.path.contains("/lib/wine/game-mode/xdt.app/") == true }
    }

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// The `wine` arguments: through `start.exe /exec` so xdt.exe is created by CreateProcess and
    /// Recall's ntdll re-execs it from xdt.app (Game Mode). A 64-bit exe given straight to `wine`
    /// runs in the first process and never reaches that hook.
    public static let wineArguments = ["start.exe", "/exec", Game.windowsExe]

    /// Launch, then (if `waitForWindow`) wait for the game's window.
    public func play(_ options: Options = Options(), waitForWindow: Bool = true,
                     log: (String) -> Void = { _ in }) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.gameExe.path) else {
            throw HeartportError(.gameNotInstalled, "Heartopia is not installed (\(paths.gameExe.path) is missing). Run `heartport install-game`.")
        }
        let snapshot = SessionSnapshot.take(paths)
        if let game = snapshot.game {
            throw HeartportError(.sessionAlive, "Heartopia is already running (pid \(game.pid)).")
        }
        // A game must start in a fresh session (the launcher's session has other displays/flags).
        try SessionGuard.requireIdle(paths, to: "start Heartopia")

        // An xdt.app from an older Heartport, or made before the game (and its icon) was there.
        if let reason = GameModeBundle.staleReason(runtime: paths.runtime, gameExe: paths.gameExe) {
            log("Regenerating the Game Mode app: \(reason)")
            try RuntimeInstaller(paths: paths).ensureGameModeBundle()
        }

        try paths.createLayout()
        if try DxmtConfig.write(to: paths.dxmtConf) { log("Wrote \(paths.dxmtConf.path)") }
        // A moved or reinstalled runtime leaves dangling ntdll.so links in the loader's cache.
        for dir in LoaderCache.removeStaleEntries() { log("Removed stale loader cache entry \(dir.lastPathComponent)") }

        let marker = Logs.dxmtInfoMarker(paths)
        let dxmtInfo = options.dxmtInfoLog ?? !fm.fileExists(atPath: marker.path)
        let gameLog = Logs.game(paths)
        try Logs.rotate(gameLog)

        let env = LaunchEnvironment.Options(hud: options.hud, dxmtInfoLog: dxmtInfo, wineDebug: options.wineDebug,
                                            inputStatsPrefix: options.inputStats ? paths.logs.appendingPathComponent("input-stats") : nil)
        let wine = Wine(paths: paths, options: env)
        let started = Date()
        let pid = try wine.spawn(Self.wineArguments, cwd: paths.gameDir, log: gameLog)
        Logs.append(paths, "play: wine pid \(pid) hud=\(options.hud) dxmtInfo=\(dxmtInfo)")
        if dxmtInfo { fm.createFile(atPath: marker.path, contents: nil) }
        try AppState.update(paths) { $0.lastLaunch = ISO8601DateFormatter().string(from: started) }
        guard waitForWindow else { return Result(winePID: pid, game: nil, window: nil, log: gameLog) }

        let deadline = started.addingTimeInterval(options.windowTimeout)
        var game: WineProcess?
        while Date() < deadline {
            let snap = SessionSnapshot.take(paths)
            game = snap.game
            if let g = game, let window = WindowInfo.game(pid: g.pid) {
                log("Window after \(Int(Date().timeIntervalSince(started))) s: \(window.owner) \(window.width)x\(window.height)")
                return Result(winePID: pid, game: g, window: window, log: gameLog)
            }
            if game == nil, kill(pid, 0) != 0, !snap.isAlive {
                // The message is shown in the app's window: no paths there; the log has them.
                Logs.append(paths, "play: wine exited before Heartopia's window appeared; see \(gameLog.path)")
                throw HeartportError(.process, "The game closed before its window appeared.")
            }
            Thread.sleep(forTimeInterval: 1)
        }
        Logs.append(paths, "play: no Heartopia window after \(Int(options.windowTimeout)) s (game pid: \(game.map { String($0.pid) } ?? "none")); see \(gameLog.path)")
        throw HeartportError(.timeout, "No game window appeared within \(Int(options.windowTimeout)) seconds.")
    }
}
