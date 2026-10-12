import Foundation

/// Whether Heartopia's exit was a normal quit or a crash. The app quits with a normal exit and
/// shows its window after a crash (docs/PLAN.md "Decisions").
///
/// Why a heuristic: Heartport starts the game as `wine start.exe /exec xdt.exe` without `/wait`,
/// so the process it spawns returns as soon as xdt.exe has been created (and Game Mode re-execs
/// xdt.exe from xdt.app under the wineserver). The game is never Heartport's child, and its exit
/// code is not visible from macOS. The rule, from what the app can observe:
///
/// 1. crash if Unity's crash marker (`Crash!!!`) is in a Player.log written since the launch;
/// 2. crash if the game ran less than `minimumRun` (20 s) from launch;
/// 3. otherwise normal.
///
/// UnityCrashHandler64.exe being alive is not a signal: it is started with the game and was
/// seen outliving it by hours after a forced stop (2026-10-12), so it would turn normal quits
/// into crashes. Not yet checked against a live crash or quit; verify the next time the game
/// is played.
public enum GameExit {
    public enum Kind: Sendable, Equatable {
        case normal
        case crash(reason: String)
    }

    public struct Facts: Sendable, Equatable {
        public var runSeconds: TimeInterval
        public var crashMarker: Bool
        public init(runSeconds: TimeInterval, crashMarker: Bool = false) {
            self.runSeconds = runSeconds; self.crashMarker = crashMarker
        }
    }

    public static let minimumRun: TimeInterval = 20
    public static let crashMarker = "Crash!!!"
    /// How much of the end of Player.log is searched for the marker.
    static let tailBytes = 256 * 1024

    public static func classify(_ f: Facts) -> Kind {
        if f.crashMarker { return .crash(reason: "Unity crash marker in Player.log") }
        if f.runSeconds < minimumRun { return .crash(reason: "ran \(Int(f.runSeconds)) s, under \(Int(minimumRun)) s") }
        return .normal
    }

    /// Unity's Player.log for every prefix user (the spike's prefix uses `crossover`, a fresh one `player`).
    public static func playerLogs(_ paths: Paths) -> [URL] {
        let users = (try? FileManager.default.contentsOfDirectory(at: paths.usersDir, includingPropertiesForKeys: nil)) ?? []
        return users.map { $0.appendingPathComponent("AppData/LocalLow/xd/Heartopia/Player.log") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A Player.log modified at or after `since` ends with Unity's crash marker in its last 256 KB.
    public static func crashMarkerInPlayerLog(_ paths: Paths, since: Date) -> Bool {
        playerLogs(paths).contains { url in
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified >= since.addingTimeInterval(-1),
                  let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
            let tail = (try? handle.readToEnd()) ?? Data()
            return tail.range(of: Data(crashMarker.utf8)) != nil
        }
    }

    /// The facts after the game was found gone. `launched`: when it was started (state.json
    /// `lastLaunch`), or when Heartport first saw it running.
    public static func facts(_ paths: Paths, launched: Date, snapshot: SessionSnapshot, now: Date = Date()) -> Facts {
        Facts(runSeconds: now.timeIntervalSince(launched),
              crashMarker: crashMarkerInPlayerLog(paths, since: launched))
    }
}
