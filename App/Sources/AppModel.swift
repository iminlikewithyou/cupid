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
    @Published private(set) var fullscreen = FullscreenMode.fill
    /// Seconds left in the TapTap download, once the rate is known.
    @Published private(set) var downloadETA: TimeInterval?
    private var downloadRate = DownloadRate()
    /// The first-run welcome screen is up (SetupPhase.needsWelcome).
    @Published private(set) var welcome = false
    /// The one-time "Heartopia is ready" screen is up (setup just finished;
    /// AppState.setupCompleteShown is not set yet).
    @Published private(set) var allSet = false
    /// TapTap was opened from Update Game: it stays open (no automatic finishing up) until it
    /// closes or Play closes it.
    @Published private(set) var updatingGame = false
    /// Free space on the data folder's volume, for the welcome screen's warning.
    @Published private(set) var freeBytes: Int64?
    private var welcomeDismissed = false
    private var allSetDone = false
    /// The window content's natural height, reported by ContentView; the window hugs it in every
    /// state, animating the change while it is on screen (top edge fixed).
    var contentHeight: CGFloat = 0 {
        didSet {
            guard abs(contentHeight - oldValue) > 0.5, contentHeight > 0 else { return }
            resizeWindow(contentHeight, oldValue > 0 && windowIsVisible())
        }
    }
    /// HEARTPORT_PREVIEW_PHASE: a fixed sample state for screenshots. Nothing is polled or run.
    private(set) var previewing = false
    private var previewHasLogs: Bool?

    /// Window plumbing, set by the AppDelegate.
    var showWindow: () -> Void = {}
    var hideWindow: () -> Void = {}
    /// Sets the window's content height, keeping its top edge (animated when asked).
    var resizeWindow: (CGFloat, Bool) -> Void = { _, _ in }
    var windowIsVisible: () -> Bool = { false }
    var presentAlert: (NSAlert, @escaping (Bool) -> Void) -> Void = { alert, done in
        done(alert.runModal() == .alertFirstButtonReturn)
    }

    private var cancelFlag: CancelFlag?
    private var refreshing = false
    private var firstRefreshDone = false
    private var timer: Timer?
    /// This app instance started (or is starting) the TapTap launcher with Heartport's flags.
    private var startedLauncher = false
    /// The launcher was running at the last refresh.
    private var launcherWasRunning = false
    /// TapTap appeared without Heartport starting it (the installer's Launch button): it renders
    /// blank without Heartport's flags, so it is restarted once the installer is gone. Set when
    /// it was first seen; the card shows "Opening TapTap…" meanwhile.
    @Published private(set) var launcherRestartPending: Date?
    private var autoLaunch: Bool
    /// The game Heartport is watching, and when it was launched (for GameExit's short-run rule).
    private var watchedGame: (pid: Int32, launched: Date)?

    init(paths: Paths, autoLaunch: Bool) {
        self.paths = paths
        self.autoLaunch = autoLaunch
    }

    var busy: Bool { activity != nil || launcherRestartPending != nil }

    /// The activity the card shows: a running operation, or the pending TapTap restart.
    var shownActivity: Activity? {
        activity ?? (launcherRestartPending != nil ? Activity(title: "Opening TapTap\u{2026}", line: "Starting TapTap") : nil)
    }

    /// The logs folder exists (Show Logs vs Show in Finder).
    var hasLogs: Bool { previewHasLogs ?? FileManager.default.fileExists(atPath: paths.logs.path) }

    /// The step dot the window highlights.
    var step: SetupStep? { phase?.step }


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
        fullscreen = preview.report?.state.fullscreen ?? .fill
        previewHasLogs = preview.hasLogs
        freeBytes = preview.freeBytes
        welcome = preview.welcome
        allSet = preview.allSet
        updatingGame = preview.updatingGame
        // After launch finishes, as the real first refresh does, so the window becomes key.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.showWindow() } }
    }

    /// Option held while opening: show the window in its current state instead of playing.
    func skipAutoLaunch() {
        autoLaunch = false
        Logs.append(paths, "app: Option held at launch; not starting the game")
    }

    func start() {
        guard !previewing else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.windowIsVisible() {
                    self.refresh()
                } else if self.watchedGame != nil {
                    self.checkGameStillRunning()
                }
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
        if let game = new.session.game {
            if watchedGame?.pid != game.pid {
                let launched = new.state.lastLaunch.flatMap { ISO8601DateFormatter().date(from: $0) }
                if GameExit.startedByHeartport(launched: launched, processStart: LiveProcesses.startTime(game.pid)) {
                    watchedGame = (game.pid, min(launched ?? Date(), Date()))
                } else {
                    // TapTap's Start Game, or another way in: watch it like our own from now on.
                    let now = Date()
                    watchedGame = (game.pid, now)
                    Logs.append(paths, "app: adopted a game started outside Heartport (pid \(game.pid))")
                    if !previewing {
                        _ = try? AppState.update(paths) { $0.lastLaunch = ISO8601DateFormatter().string(from: now) }
                    }
                }
            }
        } else if watchedGame != nil {
            gameExited()
        }
        noteLauncher(new.session.launcherRunning, first: !firstRefreshDone)
        report = new
        // Hold the step while an operation runs: restarting TapTap takes the process list
        // through several states in a few seconds, and the step dots flipped between TapTap
        // and Download with it (fresh run 3). The operation's completion refreshes.
        if activity == nil || phase == nil { phase = new.phase }
        hud = new.state.hud ?? false
        fullscreen = new.state.fullscreen
        freeBytes = Self.availableBytes(near: paths.dataRoot)
        welcome = !welcomeDismissed && (phase?.needsWelcome(runtimeInstalled: new.runtime.installedVersion != nil,
                                                            welcomed: new.state.welcomed == true) ?? false)
        if !new.session.launcherRunning { updatingGame = false }
        // Only straight after setup: an install that already played (auto-launch) never sees it.
        switch phase {
        case .ready(.idle)?: allSet = new.state.setupCompleteShown != true && !allSetDone
        case .ready(.launcherOpen)?, .ready(.sessionBusy)?: break // finishing up comes first
        default: allSet = false
        }
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
                return
            }
            showWindow()
        }
        let justDownloaded: Bool = if case .download? = old, case .ready? = phase { true } else { false }
        if activity == nil, !updatingGame, phase == .ready(.launcherOpen) || phase == .ready(.sessionBusy) {
            // The game is complete: TapTap (or a leftover program) is no longer needed, and its
            // own Start Game would run Heartopia outside Heartport. Close it without asking,
            // before anything else (the md5 check of a new download comes after).
            finishUp(checkDownload: justDownloaded)
            return
        }
        if activity == nil, let since = launcherRestartPending, case .download = phase,
           !new.session.installerRunning || Date().timeIntervalSince(since) > 10 {
            // The installer's Launch opened TapTap without Heartport's flags (blank window). Once
            // the installer has closed (or after 10 s: TapTap is installed by then), restart it.
            launcherRestartPending = nil
            openLauncherForDownload(restart: true)
            return
        }
        guard !busy, let old, let phase else { return }
        switch (old, phase) {
        case (.download, .ready(let state)):
            if case .gameRunning = state { break } // started from TapTap: adopted above
            finishUp(checkDownload: true)
        default:
            break
        }
    }

    /// Tracks who started TapTap (see `launcherRestartPending`).
    private func noteLauncher(_ running: Bool, first: Bool) {
        defer { launcherWasRunning = running }
        if first { return } // already open when Heartport started: leave it alone
        if !running {
            launcherRestartPending = nil
            if activity == nil { startedLauncher = false }
        } else if !launcherWasRunning, !startedLauncher, launcherRestartPending == nil {
            Logs.append(paths, "app: TapTap opened without Heartport's settings; restarting it")
            launcherRestartPending = Date()
        }
    }

    // MARK: running work off the main thread

    func perform<T: Sendable>(_ title: String, cancellable: Bool = false, failureTitle: String? = nil,
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
                            if !cancelled { Logs.append(self.paths, "app: \(title) failed: \(Self.message(error))") }
                            self.failure = cancelled ? nil : [failureTitle, Self.windowMessage(error)].compactMap { $0 }.joined(separator: " ")
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

    /// The window's wording for a failure: core messages that name processes, pids or commands
    /// become plain text (the log keeps `message`).
    static func windowMessage(_ error: Error) -> String {
        if let e = error as? HeartportError {
            switch e.kind {
            case .sessionAlive: return "Heartport is still finishing the previous step. Try again in a moment."
            case .timeout, .process: return "Heartport couldn't finish the previous step. Try again."
            default: break
            }
        }
        return message(error)
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

    /// "Get Started": the welcome screen never returns for this data folder.
    func getStarted() {
        welcomeDismissed = true
        if !previewing {
            do { try AppState.update(paths) { $0.welcomed = true } } catch {
                Logs.append(paths, "app: could not save welcomed: \(Self.message(error))")
            }
        }
        welcome = false
    }

    /// volumeAvailableCapacityForImportantUsage of the volume `url` is on (or will be on).
    static func availableBytes(near url: URL) -> Int64? {
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        return (try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

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
            if !snapshot.installer.isEmpty { // already open
                _ = Operations.bringToFront(paths, timeout: 2) { $0.installer }
                return nil
            }
            if snapshot.isAlive {
                // Between the installer's stages, or a session winding down.
                r.line("Waiting for the previous step to finish")
                if !Session.waitForExit(paths: paths, timeout: 15) {
                    Logs.append(paths, "app: session still alive after 15 s; not starting the installer")
                }
            }
            try SessionGuard.requireIdle(paths, to: "start the TapTap installer")
            r.line("Downloading the TapTap Global installer")
            return try TapTapInstaller.download(paths, progress: Operations.byteProgress(r, "TapTap installer"))
        } then: { check in
            switch check {
            case nil:
                break
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
            r.line("Opening the installer")
            let pid = try TapTapInstaller.run(paths)
            Logs.append(paths, "app: TapTap installer started (wine pid \(pid))")
            if !Operations.bringToFront(paths, timeout: 15, { $0.installer }) {
                Logs.append(paths, "app: no installer window after 15 s")
            }
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
    /// The card shows "Opening TapTap…" with its buttons disabled until TapTap's window is on
    /// screen (or 25 s pass): TapTap takes several seconds to show it.
    func openLauncherForDownload(restart: Bool) {
        guard activity == nil, !previewing else { return }
        let paths = paths
        startedLauncher = true
        perform("Opening TapTap\u{2026}") { r in
            let started = Date()
            let snapshot = SessionSnapshot.take(paths)
            if let game = snapshot.game {
                throw HeartportError(.sessionAlive, "Heartopia is running (pid \(game.pid)); quit it first.")
            }
            if restart, snapshot.isAlive {
                r.line("Restarting TapTap")
                Logs.append(paths, "app: restarting TapTap with Heartport's settings")
                try Session.stop(paths: paths, log: Logs.stop(paths))
            } else if snapshot.launcher.isEmpty, snapshot.isAlive {
                // The installer's session takes a few seconds to wind down after it closes.
                r.line("Waiting for the previous step to finish")
                if !Session.waitForExit(paths: paths, timeout: 15) {
                    Logs.append(paths, "app: session still alive after 15 s; trying to open TapTap anyway")
                }
            }
            r.line("Starting TapTap")
            if let pid = try TapTapLauncher.run(paths) { Logs.append(paths, "app: launcher started (wine pid \(pid))") }
            r.line("Waiting for TapTap's window")
            let left = max(2, 25 - Date().timeIntervalSince(started))
            if !Operations.bringToFront(paths, timeout: left, { $0.launcher }) {
                Logs.append(paths, "app: no TapTap window after 25 s")
            }
        }
    }

    /// The download just completed: md5-sample it once (as `heartport install-game` does).
    /// Ends the session that is still open now that the game is complete (TapTap after the
    /// download, or programs left over from an earlier session), with no confirmation, and
    /// after a download md5-checks a sample of it once (as `heartport install-game` does).
    private func finishUp(checkDownload: Bool) {
        let paths = paths
        perform("Finishing up\u{2026}") { r -> String? in
            let snapshot = SessionSnapshot.take(paths)
            if snapshot.game == nil, snapshot.isAlive || !snapshot.processes.isEmpty {
                r.line(snapshot.launcher.isEmpty ? "Closing the previous session" : "Closing TapTap")
                let started = Date()
                Logs.append(paths, "app: game complete; ending the open session (\(snapshot.windowsPrograms.compactMap(\.programName).joined(separator: ", ")))")
                do {
                    try Session.stop(paths: paths, log: Logs.stop(paths))
                    Logs.append(paths, String(format: "app: session ended in %.1f s", Date().timeIntervalSince(started)))
                } catch {
                    Logs.append(paths, String(format: "app: ending the session failed after %.1f s", Date().timeIntervalSince(started)))
                    throw error
                }
            }
            guard checkDownload else { return nil }
            r.line("Checking the downloaded files")
            let checked = Date()
            let state = GameInstall.state(paths)
            Logs.append(paths, String(format: "app: download check took %.1f s", Date().timeIntervalSince(checked)))
            switch state {
            case .installed:
                try AppState.update(paths) { $0.gameInstalled = true }
                return nil
            case .incomplete(let c):
                return "\(c.md5Mismatch.count) of \(c.md5Checked) checked game files are damaged. Use TapTap's verify (Update Game) or Repair."
            default:
                return "The download is not complete yet."
            }
        } then: { problem in
            if let problem { self.failure = problem }
        }
    }

    /// The all-set screen's Play (or any game start): the screen is not shown again.
    private func markSetupComplete() {
        allSetDone = true
        allSet = false
        guard !previewing, report?.state.setupCompleteShown != true else { return }
        do { try AppState.update(paths) { $0.setupCompleteShown = true } } catch {
            Logs.append(paths, "app: could not save setupCompleteShown: \(Self.message(error))")
        }
    }

    // MARK: ready state and menu actions

    /// Start the game. With `auto` the window stays hidden unless it fails. A TapTap (or other
    /// session of ours) that is still open is closed first, without asking.
    func play(auto: Bool = false) {
        guard !previewing else { return }
        guard let report else { return }
        if let game = report.session.game { showHeartopia(pid: game.pid); return }
        startGame(stopFirst: report.session.alive, auto: auto)
    }

    private func startGame(stopFirst: Bool, auto: Bool) {
        guard activity == nil else { return }
        let paths = paths
        markSetupComplete()
        updatingGame = false
        if !auto { hideWindow() }
        let started = Date()
        perform("Starting Heartopia", failureTitle: "Heartopia didn't start.") { r in
            if stopFirst {
                let snapshot = SessionSnapshot.take(paths)
                if let game = snapshot.game { throw HeartportError(.sessionAlive, "Heartopia is already running (pid \(game.pid)).") }
                r.line(snapshot.launcher.isEmpty ? "Closing the previous session" : "Closing TapTap")
                try Session.stop(paths: paths, log: Logs.stop(paths))
            }
            let options = GameLauncher.Options(state: AppState.load(paths))
            r.line("Starting Heartopia")
            let result = try GameLauncher(paths: paths).play(options, waitForWindow: true, log: { r.line($0) })
            return result.game?.pid
        } then: { pid in
            if let pid {
                self.watchedGame = (pid, started)
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
            }
        }
    }

    // MARK: game exit (docs/PLAN.md "Decisions": quit with the game)

    /// While the window is hidden only the process list is checked (StatusReport.gather is heavier).
    private func checkGameStillRunning() {
        guard let watched = watchedGame, !refreshing else { return }
        let paths = paths
        Task.detached(priority: .utility) {
            let gone = SessionSnapshot.take(paths).game?.pid != watched.pid
            await MainActor.run {
                if gone, self.watchedGame?.pid == watched.pid { self.gameExited() }
            }
        }
    }

    /// The watched game is gone. Normal exit: quit if the window is hidden (after up to 5 s for
    /// the wineserver to finish, so the next launch finds an idle session), else stay in the ready
    /// state. Crash (GameExit's rule): show the window with a callout; never quit.
    private func gameExited() {
        guard let watched = watchedGame, !previewing else { return }
        watchedGame = nil
        let paths = paths
        Task.detached(priority: .userInitiated) {
            let facts = GameExit.facts(paths, launched: watched.launched, snapshot: SessionSnapshot.take(paths))
            let kind = GameExit.classify(facts)
            switch kind {
            case .normal:
                Logs.append(paths, "app: Heartopia (pid \(watched.pid)) exited after \(Int(facts.runSeconds)) s: normal")
            case .crash(let reason):
                Logs.append(paths, "app: Heartopia (pid \(watched.pid)) exited after \(Int(facts.runSeconds)) s: crash (\(reason))")
            }
            await MainActor.run {
                if case .crash = kind {
                    self.failure = "Heartopia stopped unexpectedly."
                    self.showWindow()
                    self.refresh()
                } else if self.windowIsVisible() {
                    self.refresh()
                } else {
                    self.quitAfterSessionEnds()
                }
            }
        }
    }

    private func quitAfterSessionEnds() {
        let paths = paths
        Task.detached(priority: .utility) {
            let idle = Session.waitForExit(paths: paths, timeout: 5)
            if !idle { Logs.append(paths, "app: wineserver still running after 5 s; quitting anyway") }
            await MainActor.run {
                // Something may have changed meanwhile (window shown from the Dock, game restarted).
                guard !self.windowIsVisible(), self.watchedGame == nil, !self.busy else { self.refresh(); return }
                Logs.append(paths, "app: quitting with the game")
                NSApp.terminate(nil)
            }
        }
    }

    func showHeartopia(pid: Int32) {
        guard !previewing else { return }
        if let app = NSRunningApplication(processIdentifier: pid), app.activate(options: [.activateAllWindows]) { return }
        failure = "Could not bring Heartopia to the front."
    }

    func updateGame() {
        let paths = paths
        startedLauncher = true
        updatingGame = true
        perform("Opening TapTap\u{2026}") { r -> Bool in
            r.line("Starting TapTap")
            let started = try TapTapLauncher.run(paths) != nil
            r.line("Waiting for TapTap's window")
            _ = Operations.bringToFront(paths, timeout: 25) { $0.launcher }
            return started
        } then: { started in
            Logs.append(paths, "app: Update Game: TapTap \(started ? "started" : "was already open")")
        }
    }

    func resetGraphics() {
        let count = RegistrySeeds.all.count
        confirm("Reset graphics settings?",
                "Puts Heartport's recommended graphics settings back, replacing any changes made in the game.",
                button: "Reset") {
            let paths = self.paths
            self.perform("Resetting graphics settings") { r in
                guard PrefixSetup(paths: paths).exists else { throw HeartportError(.prefixMissing, "The Wine prefix does not exist yet.") }
                try SessionGuard.requireIdle(paths, to: "reset the graphics settings")
                try PrefixSetup(paths: paths).apply(RegistrySeeds.all.map(PrefixSetup.Step.seed), log: Operations.detail(paths))
                Logs.append(paths, "app: reset-graphics (\(count) values)")
            } then: { _ in
                self.notice = "Graphics settings restored."
            }
        }
    }

    func showLogs() {
        guard !previewing else { return }
        if FileManager.default.fileExists(atPath: paths.logs.path) {
            NSWorkspace.shared.open(paths.logs)
        } else {
            notice = "There are no logs yet."
            showWindow()
        }
    }

    func repair() {
        confirm("Repair Heartport?",
                "Reinstalls Heartport's runtime, re-checks the Windows environment, and checks every Heartopia file. Your game data and settings are kept. This can take several minutes.",
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
                "Moves \(paths.dataRoot.path) to the Trash: the Wine runtime, the Windows prefix with TapTap and Heartopia (about 15 GB), caches, and logs. Heartport itself stays installed; open it again to set everything up from scratch.",
                button: "Move to Trash", destructive: true) {
            let paths = self.paths
            self.perform("Uninstalling") { r -> String in
                let fm = FileManager.default
                guard fm.fileExists(atPath: paths.dataRoot.path) else { return "Nothing to remove." }
                try SessionGuard.requireIdle(paths, to: "uninstall")
                r.line("Moving \(paths.dataRoot.lastPathComponent) to the Trash")
                // No log line afterwards: writing one would recreate the data folder.
                try fm.trashItem(at: paths.dataRoot, resultingItemURL: nil)
                return "Heartport's data folder is in the Trash."
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

    func setFullscreen(_ mode: FullscreenMode) {
        if previewing { fullscreen = mode; return }
        do {
            try AppState.update(paths) { $0.setFullscreen(mode) }
            fullscreen = mode
        } catch {
            failure = "Could not save the setting: \(Self.message(error))"
        }
    }
}
