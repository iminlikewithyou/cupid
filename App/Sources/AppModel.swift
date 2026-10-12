import AppKit
import HeartportCore

/// Set from the UI, read by background work between steps.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// A long operation in progress: what it is, its last progress line, and whether it can stop.
struct Activity: Equatable {
    var title: String
    var line = ""
    var fraction: Double?
    var cancellable = false
    var cancelling = false
}

/// Handed to background work: posts progress to the window in order (main queue is FIFO).
struct Reporter: Sendable {
    let model: AppModel
    let flag: CancelFlag
    func line(_ text: String) {
        let model = model
        DispatchQueue.main.async { MainActor.assumeIsolated { model.activity?.line = text } }
    }
    func fraction(_ value: Double?) {
        let model = model
        DispatchQueue.main.async { MainActor.assumeIsolated { model.activity?.fraction = value } }
    }
    var isCancelled: Bool { flag.isCancelled }
    func checkCancelled() throws {
        if flag.isCancelled { throw HeartportError(.cancelled, "Cancelled.") }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let paths: Paths
    @Published private(set) var report: StatusReport?
    @Published private(set) var phase: SetupPhase?
    @Published var activity: Activity?
    /// The last failure, shown in the window until the next action.
    @Published var failure: String?
    /// The last informational result (repair summary, "TapTap is not installed yet", ...).
    @Published var notice: String?
    @Published private(set) var hud = false
    /// Seconds left in the TapTap download, once the rate is known.
    @Published private(set) var downloadETA: TimeInterval?
    private var downloadRate = DownloadRate()
    /// HEARTPORT_PREVIEW_PHASE: a fixed sample state for screenshots. Nothing is polled or run.
    private(set) var previewing = false
    private var previewHasLogs: Bool?

    /// Window plumbing, set by the AppDelegate.
    var showWindow: () -> Void = {}
    var hideWindow: () -> Void = {}
    var windowIsVisible: () -> Bool = { false }
    var presentAlert: (NSAlert, @escaping (Bool) -> Void) -> Void = { alert, done in
        done(alert.runModal() == .alertFirstButtonReturn)
    }

    private var cancelFlag: CancelFlag?
    private var refreshing = false
    private var firstRefreshDone = false
    private var timer: Timer?
    /// This app instance started the TapTap launcher with Heartport's flags.
    private var startedLauncher = false
    private let autoLaunch: Bool

    init(paths: Paths, autoLaunch: Bool) {
        self.paths = paths
        self.autoLaunch = autoLaunch
    }

    var busy: Bool { activity != nil }

    /// The logs folder exists (Show Logs vs Show in Finder).
    var hasLogs: Bool { previewHasLogs ?? FileManager.default.fileExists(atPath: paths.logs.path) }

    /// The step dot the window highlights.
    var step: SetupStep? { phase?.step }

    /// When Heartopia was last started (state.json `lastLaunch`).
    var lastPlayed: Date? {
        report?.state.lastLaunch.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    // MARK: status

    /// Shows `preview` instead of the real status, and makes every action inert.
    func showPreview(_ preview: Preview) {
        previewing = true
        report = preview.report
        phase = preview.phase
        activity = preview.activity
        failure = preview.failure
        notice = preview.notice
        downloadETA = preview.eta
        hud = preview.report?.state.hud ?? false
        previewHasLogs = preview.hasLogs
        // After launch finishes, as the real first refresh does, so the window becomes key.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.showWindow() } }
    }

    func start() {
        guard !previewing else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.windowIsVisible() else { return }
                self.refresh()
            }
        }
    }

    /// Re-gather the status off the main thread (read-only).
    func refresh(then: (@MainActor () -> Void)? = nil) {
        guard !previewing else { return }
        guard !refreshing else { return }
        refreshing = true
        let paths = paths
        Task.detached(priority: .userInitiated) {
            let report = StatusReport.gather(paths)
            await MainActor.run {
                self.refreshing = false
                self.apply(report)
                then?()
            }
        }
    }

    private func apply(_ new: StatusReport) {
        let old = phase
        report = new
        phase = new.phase
        hud = new.state.hud ?? false
        if case .download(let d)? = phase, let have = d.bytesOnDisk, let total = d.totalBytes {
            downloadRate.add(bytes: have, at: Date())
            downloadETA = downloadRate.eta(remaining: total - have)
        } else {
            downloadRate.reset()
            downloadETA = nil
        }

        if !firstRefreshDone {
            firstRefreshDone = true
            if autoLaunch, phase?.canAutoLaunch == true {
                play(auto: true) // the window stays hidden unless this fails
            } else {
                showWindow()
            }
            return
        }
        guard !busy, let old, let phase else { return }
        switch (old, phase) {
        case (.taptap, .download(let d)) where d.launcherRunning && !new.session.installerRunning && !startedLauncher:
            // The installer opens TapTap without Heartport's flags (blank Electron window).
            openLauncherForDownload(restart: true)
        case (.download, .ready):
            confirmDownload()
        default:
            break
        }
    }

    // MARK: running work off the main thread

    func perform<T: Sendable>(_ title: String, cancellable: Bool = false,
                              _ work: @escaping @Sendable (Reporter) throws -> T,
                              then: @escaping @MainActor (T) -> Void = { _ in }) {
        guard activity == nil, !previewing else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        failure = nil
        notice = nil
        activity = Activity(title: title, cancellable: cancellable)
        let reporter = Reporter(model: self, flag: flag)
        Task.detached(priority: .userInitiated) {
            let result = Result { try work(reporter) }
            await MainActor.run {
                // Let queued progress lines land first, then clear.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.activity = nil
                        self.cancelFlag = nil
                        switch result {
                        case .success(let value): then(value)
                        case .failure(let error):
                            let cancelled = (error as? HeartportError)?.kind == .cancelled
                            self.failure = cancelled ? nil : Self.message(error)
                            if cancelled { self.notice = "\(title): cancelled." }
                            self.showWindow()
                        }
                        self.refresh()
                    }
                }
            }
        }
    }

    func cancel() {
        guard !previewing else { return }
        cancelFlag?.cancel()
        activity?.cancelling = true
    }

    static func message(_ error: Error) -> String {
        if let e = error as? HeartportError { return e.message }
        return error.localizedDescription
    }

    private func confirm(_ title: String, _ text: String, button: String, destructive: Bool = false,
                         _ yes: @escaping @MainActor () -> Void) {
        guard !previewing else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = destructive ? .critical : .informational
        let ok = alert.addButton(withTitle: button)
        ok.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        showWindow()
        presentAlert(alert) { confirmed in
            MainActor.assumeIsolated { if confirmed { yes() } }
        }
    }

    // MARK: setup states

    func openRosettaInstructions() {
        guard !previewing else { return }
        NSWorkspace.shared.open(URL(string: "https://support.apple.com/en-us/102527")!)
    }

    /// Runtime then prefix, whatever is missing (the "Set up" button of both states).
    func runSetup() {
        let paths = paths
        perform("Setting up") { r in
            try Operations.installRuntimeIfNeeded(paths, r, replace: false)
            try Operations.setUpPrefixIfNeeded(paths, r)
        }
    }

    func launchInstaller() {
        let paths = paths
        perform("Preparing the TapTap installer") { r -> TapTapInstaller.Check? in
            let snapshot = SessionSnapshot.take(paths)
            if !snapshot.installer.isEmpty { return nil } // already open
            try SessionGuard.requireIdle(paths, to: "start the TapTap installer")
            r.line("Downloading the TapTap Global installer")
            return try TapTapInstaller.download(paths, progress: Operations.byteProgress(r, "TapTap installer"))
        } then: { check in
            switch check {
            case nil:
                self.notice = "The TapTap installer is already open."
            case .pinned?:
                self.runInstaller()
            case .missing?:
                self.failure = "The installer download is missing."
            case .changed(let bytes, let sha)?:
                if AppState.load(self.paths).acceptedInstallerSHA256 == sha { self.runInstaller(); return }
                self.confirm("TapTap updated its installer",
                             "The downloaded installer (\(bytes) bytes, sha256 \(sha)) is not the one Heartport was tested with (\(TapTapInstaller.bytes) bytes). Run it anyway?",
                             button: "Run Installer") {
                    _ = try? AppState.update(self.paths) { $0.acceptedInstallerSHA256 = sha }
                    self.runInstaller()
                }
            }
        }
    }

    private func runInstaller() {
        let paths = paths
        perform("Starting the TapTap installer") { r in
            r.line("Opening \"Welcome to TapTap Setup\"")
            let pid = try TapTapInstaller.run(paths)
            Logs.append(paths, "app: TapTap installer started (wine pid \(pid))")
        }
    }

    /// "I've installed it".
    func recheckTapTap() {
        guard !previewing else { return }
        notice = nil
        refresh {
            if case .taptap(let running)? = self.phase {
                self.notice = running
                    ? "TapTap is not installed yet. Finish the steps in the installer window, then check again."
                    : "TapTap is not installed yet. Launch the installer and follow the steps above."
            }
        }
    }

    /// Start TapTap with the flags that make its window render. `restart`: end a running
    /// launcher first (one the installer opened without them renders blank).
    func openLauncherForDownload(restart: Bool) {
        let paths = paths
        perform(restart ? "Restarting TapTap" : "Opening TapTap") { r in
            let snapshot = SessionSnapshot.take(paths)
            if let game = snapshot.game {
                throw HeartportError(.sessionAlive, "Heartopia is running (pid \(game.pid)); quit it first.")
            }
            if restart, snapshot.isAlive, snapshot.installer.isEmpty {
                r.line("Closing the TapTap window that was opened without Heartport's settings")
                try Session.stop(paths: paths, log: Logs.stop(paths))
            }
            r.line("Starting TapTapGlobal.exe")
            if let pid = try TapTapLauncher.run(paths) { Logs.append(paths, "app: launcher started (wine pid \(pid))") }
        } then: { _ in
            self.startedLauncher = true
        }
    }

    /// The download just completed: md5-sample it once (as `heartport install-game` does).
    private func confirmDownload() {
        let paths = paths
        perform("Checking the downloaded files") { r -> String? in
            r.line("Checking file sizes and a sample of md5 sums")
            let state = GameInstall.state(paths)
            switch state {
            case .installed:
                try AppState.update(paths) { $0.gameInstalled = true }
                return nil
            case .incomplete(let c):
                return "\(c.md5Mismatch.count) of \(c.md5Checked) sampled files differ from TapTap's manifest. Use TapTap's verify (Update Game) or Repair."
            default:
                return "The download is not complete yet."
            }
        } then: { problem in
            if let problem { self.failure = problem }
            else { self.notice = "Heartopia is installed. Close the TapTap window, then press Play." }
        }
    }

    // MARK: ready state and menu actions

    /// Start the game. With `auto` the window stays hidden unless it fails. When the TapTap
    /// launcher (or another session of ours) is open, asks to close it first.
    func play(auto: Bool = false) {
        guard !previewing else { return }
        guard let report else { return }
        if let game = report.session.game { showHeartopia(pid: game.pid); return }
        if report.session.alive {
            let what = report.session.launcherRunning ? "The TapTap launcher is open" : "A Heartport Wine session is still running"
            confirm("Close TapTap and play?", "\(what). Heartopia starts in a fresh session, so it will be closed first.",
                    button: "Close and Play") { self.startGame(stopFirst: true, auto: false) }
            return
        }
        startGame(stopFirst: false, auto: auto)
    }

    private func startGame(stopFirst: Bool, auto: Bool) {
        let paths = paths
        if !auto { hideWindow() }
        perform("Starting Heartopia") { r in
            if stopFirst {
                let snapshot = SessionSnapshot.take(paths)
                if let game = snapshot.game { throw HeartportError(.sessionAlive, "Heartopia is already running (pid \(game.pid)).") }
                r.line("Closing the open Wine session")
                try Session.stop(paths: paths, log: Logs.stop(paths))
            }
            let hud = AppState.load(paths).hud ?? false
            r.line("Starting Heartopia")
            let result = try GameLauncher(paths: paths).play(.init(hud: hud), waitForWindow: true, log: { r.line($0) })
            return result.game?.pid
        } then: { pid in
            if let pid { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) }
        }
    }

    func showHeartopia(pid: Int32) {
        guard !previewing else { return }
        if let app = NSRunningApplication(processIdentifier: pid), app.activate(options: [.activateAllWindows]) { return }
        failure = "Could not bring Heartopia (pid \(pid)) to the front."
    }

    func updateGame() {
        let paths = paths
        perform("Opening TapTap") { r -> Bool in
            r.line("Starting TapTapGlobal.exe")
            return try TapTapLauncher.run(paths) != nil
        } then: { started in
            if started { self.startedLauncher = true }
            self.notice = (started ? "TapTap is open." : "TapTap is already open.")
                + " If it offers a Heartopia update, run it. Then close TapTap and press Play."
        }
    }

    func resetGraphics() {
        let count = RegistrySeeds.all.count
        confirm("Reset graphics settings?",
                "This re-applies Heartport's \(count) defaults (Retina mode off, High quality, 3840x2160@60 entry, UI 85%, ...) over any changes made in the game.",
                button: "Reset") {
            let paths = self.paths
            self.perform("Resetting graphics settings") { r in
                guard PrefixSetup(paths: paths).exists else { throw HeartportError(.prefixMissing, "The Wine prefix does not exist yet.") }
                try SessionGuard.requireIdle(paths, to: "reset the graphics settings")
                try PrefixSetup(paths: paths).apply(RegistrySeeds.all.map(PrefixSetup.Step.seed), log: { r.line($0) })
                Logs.append(paths, "app: reset-graphics")
            } then: { _ in
                self.notice = "Graphics settings reset to Heartport's defaults."
            }
        }
    }

    func showLogs() {
        guard !previewing else { return }
        if FileManager.default.fileExists(atPath: paths.logs.path) {
            NSWorkspace.shared.open(paths.logs)
        } else {
            notice = "There are no logs yet (\(paths.logs.path))."
            showWindow()
        }
    }

    func repair() {
        confirm("Repair Heartport?",
                "Reinstalls the Wine runtime from the copy inside Heartport, re-checks the Wine prefix, and checks every Heartopia file against TapTap's manifest. Your game data and settings are kept. This can take several minutes.",
                button: "Repair") {
            let paths = self.paths
            self.perform("Repairing", cancellable: true) { r in
                try Operations.repair(paths, r)
            } then: { summary in
                self.notice = summary
                self.showWindow()
            }
        }
    }

    func uninstall() {
        confirm("Uninstall Heartopia and its Windows environment?",
                "Moves \(paths.dataRoot.path) to the Trash: the Wine runtime, the Windows prefix with TapTap and Heartopia (about 15 GB), caches and logs. Heartport itself stays installed; open it again to set everything up from scratch.",
                button: "Move to Trash", destructive: true) {
            let paths = self.paths
            self.perform("Uninstalling") { r -> String in
                let fm = FileManager.default
                guard fm.fileExists(atPath: paths.dataRoot.path) else { return "Nothing to remove." }
                try SessionGuard.requireIdle(paths, to: "uninstall")
                r.line("Moving \(paths.dataRoot.lastPathComponent) to the Trash")
                var trashed: NSURL?
                try fm.trashItem(at: paths.dataRoot, resultingItemURL: &trashed)
                return "Moved to the Trash: \(trashed?.path ?? paths.dataRoot.path)"
            } then: { message in
                self.notice = message
            }
        }
    }

    func setHUD(_ on: Bool) {
        if previewing { hud = on; return }
        do {
            try AppState.update(paths) { $0.hud = on }
            hud = on
        } catch {
            failure = "Could not save the setting: \(Self.message(error))"
        }
    }
}
