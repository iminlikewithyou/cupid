import Foundation
import HeartportCore

/// HEARTPORT_PREVIEW_PHASE=<name> renders one setup state with sample data, for screenshots and
/// design review. The model then polls nothing and every action is inert (AppModel.previewing).
/// HEARTPORT_PREVIEW_SETTINGS=1 also opens the Settings window, HEARTPORT_PREVIEW_ABOUT=1 the
/// About window.
struct Preview {
    var phase: SetupPhase?
    var activity: Activity?
    var failure: String?
    var notice: String?
    var eta: TimeInterval?
    var report: StatusReport?
    var hasLogs = true
    var welcome = false
    var allSet = false
    var updatingGame = false
    var freeBytes: Int64? = 250_000_000_000

    /// Every name, in setup order.
    static let names = [
        "welcome", "welcome-low-space", "checking", "rosetta-missing",
        "runtime", "runtime-installing",
        "windows", "windows-setting-up", "windows-update",
        "taptap-install", "taptap-preparing", "taptap-installing",
        "download-waiting", "download", "download-restart", "download-incomplete", "download-checking",
        "all-set", "ready", "ready-hud", "finishing-up", "ready-updating", "ready-launcher-open", "ready-session-busy", "game-running",
        "launch-failed", "notice", "repairing",
    ]

    /// AppModel phase names accepted as well.
    static let aliases = [
        "rosettaMissing": "rosetta-missing", "prefix": "windows", "taptap": "taptap-install",
        "ready-idle": "ready", "gameRunning": "game-running", "launcherOpen": "ready-launcher-open",
        "sessionBusy": "ready-session-busy",
    ]

    private static let total: Int64 = 13_935_655_934

    static func named(_ raw: String) -> Preview? {
        let name = aliases[raw] ?? raw
        guard names.contains(name) else { return nil }
        var p = Preview(report: sampleReport(installed: name.hasPrefix("ready") || name.hasPrefix("game")
                                               || ["all-set", "finishing-up", "launch-failed", "notice", "repairing"].contains(name)))
        switch name {
        case "welcome":
            p.phase = .runtime
            p.welcome = true
            p.hasLogs = false
        case "welcome-low-space":
            p.phase = .runtime
            p.welcome = true
            p.hasLogs = false
            p.freeBytes = 9_400_000_000
        case "checking":
            p.phase = nil
            p.hasLogs = false
        case "rosetta-missing":
            p.phase = .rosettaMissing
            p.hasLogs = false
        case "runtime":
            p.phase = .runtime
            p.hasLogs = false
        case "runtime-installing":
            p.phase = .runtime
            p.activity = Activity(title: "Setting up", line: "Installing the game runtime")
        case "windows":
            p.phase = .prefix(exists: false)
        case "windows-setting-up":
            p.phase = .prefix(exists: false)
            p.activity = Activity(title: "Setting up", line: "Creating the Windows environment")
        case "windows-update":
            p.phase = .prefix(exists: true)
        case "taptap-install":
            p.phase = .taptap(installerRunning: false)
        case "taptap-preparing":
            p.phase = .taptap(installerRunning: false)
            p.activity = Activity(title: "Preparing the TapTap installer",
                                  line: "TapTap installer: 31.5 MB of 78.7 MB (40%)", fraction: 0.4)
        case "taptap-installing":
            p.phase = .taptap(installerRunning: true)
        case "download-waiting":
            p.phase = .download(.init(launcherRunning: false))
        case "download":
            p.phase = .download(download(5_412_000_000, launcherRunning: true))
            p.eta = 21 * 60
        case "download-restart":
            p.phase = .download(.init(launcherRunning: true))
            p.activity = Activity(title: "Opening TapTap\u{2026}", line: "Waiting for TapTap's window")
        case "download-incomplete":
            var d = download(total, launcherRunning: true)
            d.incomplete = true
            p.phase = .download(d)
        case "download-checking":
            p.phase = .download(download(total, launcherRunning: true))
            p.activity = Activity(title: "Checking the downloaded files", line: "Checking file sizes and a sample of md5 sums")
        case "all-set":
            p.phase = .ready(.idle)
            p.allSet = true
        case "ready":
            p.phase = .ready(.idle)
        case "ready-hud":
            p.phase = .ready(.idle)
            p.report?.state.hud = true
        case "finishing-up":
            p.phase = .ready(.launcherOpen)
            p.activity = Activity(title: "Finishing up\u{2026}", line: "Closing TapTap")
        case "ready-updating":
            p.phase = .ready(.launcherOpen)
            p.updatingGame = true
        case "ready-launcher-open":
            p.phase = .ready(.launcherOpen)
        case "ready-session-busy":
            p.phase = .ready(.sessionBusy)
        case "game-running":
            p.phase = .ready(.gameRunning(pid: 4242))
            p.report?.session.alive = true
            p.report?.session.gameInModeBundle = true
        case "launch-failed":
            p.phase = .ready(.idle)
            p.failure = "Heartopia didn't start. The game closed before its window appeared."
        case "notice":
            p.phase = .ready(.idle)
            p.notice = "Graphics settings restored."
        case "repairing":
            p.phase = .ready(.idle)
            p.activity = Activity(title: "Repairing", line: "Checking game files: 1450 of 3712", fraction: 0.39, cancellable: true)
        default:
            return nil
        }
        return p
    }

    private static func download(_ have: Int64, launcherRunning: Bool) -> SetupPhase.Download {
        .init(launcherRunning: launcherRunning, bytesOnDisk: have, totalBytes: total,
              fraction: Double(have) / Double(total))
    }

    /// A status gathered from a data root that does not exist (read-only; nothing is created),
    /// then filled in as an installed game (HUD off, as on a fresh install).
    private static func sampleReport(installed: Bool) -> StatusReport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartport-preview-does-not-exist-\(UUID().uuidString)", isDirectory: true)
        var r = StatusReport.gather(Paths(dataRoot: root))
        guard installed else { return r }
        r.runtime.installedVersion = r.runtime.expectedVersion
        r.runtime.gameModeBundle = true
        r.runtime.gameModeBundleIdentifier = GameModeBundle.identifier
        r.prefix.exists = true
        r.taptap.launcherInstalled = true
        r.game.state = "installed"
        r.game.version = "0.5.5"
        r.game.build = "5847751"
        r.state.fullscreenMode = FullscreenMode.fill.rawValue
        r.state.lastLaunch = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))
        return r
    }
}
