import Foundation
import HeartportCore

/// HEARTPORT_PREVIEW_PHASE=<name> renders one setup state with sample data, for screenshots and
/// design review. The model then polls nothing and every action is inert (AppModel.previewing).
/// HEARTPORT_PREVIEW_SETTINGS=1 also opens the Settings window.
struct Preview {
    var phase: SetupPhase?
    var activity: Activity?
    var failure: String?
    var notice: String?
    var eta: TimeInterval?
    var report: StatusReport?
    var hasLogs = true

    /// Every name, in setup order.
    static let names = [
        "checking", "rosetta-missing",
        "runtime", "runtime-installing",
        "windows", "windows-setting-up", "windows-update",
        "taptap-install", "taptap-preparing", "taptap-installing",
        "download-waiting", "download", "download-restart", "download-incomplete", "download-checking",
        "ready", "ready-launcher-open", "ready-session-busy", "game-running",
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
                                               || ["launch-failed", "notice", "repairing"].contains(name)))
        switch name {
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
            p.activity = Activity(title: "Setting up", line: "Verifying every file against runtime.json")
        case "windows":
            p.phase = .prefix(exists: false)
        case "windows-setting-up":
            p.phase = .prefix(exists: false)
            p.activity = Activity(title: "Setting up", line: "Creating the Windows environment (about a minute)")
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
            p.activity = Activity(title: "Restarting TapTap",
                                  line: "Closing the TapTap window that was opened without Heartport's settings")
        case "download-incomplete":
            var d = download(total, launcherRunning: true)
            d.incomplete = true
            p.phase = .download(d)
        case "download-checking":
            p.phase = .download(download(total, launcherRunning: true))
            p.activity = Activity(title: "Checking the downloaded files", line: "Checking file sizes and a sample of md5 sums")
        case "ready":
            p.phase = .ready(.idle)
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
            p.failure = "Wine exited before Heartopia's window appeared (see ~/Library/Application Support/Heartport/logs/game.log)."
        case "notice":
            p.phase = .ready(.idle)
            p.notice = "Graphics settings reset to Heartport's defaults."
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
    /// then filled in so the ready state has its Game Mode check, last-played time and HUD.
    private static func sampleReport(installed: Bool) -> StatusReport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartport-preview-does-not-exist-\(UUID().uuidString)", isDirectory: true)
        var r = StatusReport.gather(Paths(dataRoot: root))
        r.state.hud = true
        guard installed else { return r }
        r.runtime.installedVersion = r.runtime.expectedVersion
        r.runtime.gameModeBundle = true
        r.runtime.gameModeBundleIdentifier = GameModeBundle.identifier
        r.prefix.exists = true
        r.taptap.launcherInstalled = true
        r.game.state = "installed"
        r.state.lastLaunch = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))
        return r
    }
}
