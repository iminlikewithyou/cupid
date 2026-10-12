import Darwin
import Foundation
import CupidCore

let usage = """
cupid: Heartopia on Cupid's Wine + DXMT runtime, through Rosetta 2

USAGE: cupid [--data DIR] <command> [options]

Commands:
  setup [--step runtime|prefix|taptap|all]   Install what is missing (default: all)
        [--archive PATH] [--repair] [--no-wait] [--wait SECONDS] [--accept-new-installer]
  install-game [--no-wait] [--wait SECONDS]  Open TapTap and follow the game download
  play [--hud|--no-hud] [--fullscreen notifications|fill|space] [--no-wait] [--dxmt-info]
       [--wine-debug SPEC] [--input-stats]   Start the game (--fullscreen default: the saved
                                             setting, else notifications)
  stop [--yes]                               End every Wine process (wineserver -k)
  status [--json] [--verify]                 Report runtime, prefix, TapTap, game, session
  update                                     Open the TapTap launcher to update the game
  logs [--lines N] [--name FILE] [--path]    Show logs (default: tail of game.log)
  reset-graphics                             Re-apply the seeded graphics settings
  uninstall [--yes]                          Move the data folder to the Trash
  verify-runtime [--archive PATH | DIR]      Verify a runtime folder or runtime.tar.gz

The data folder is ~/Library/Application Support/Cupid (override: --data or CUPID_DATA_ROOT).
setup installs the runtime bundled with the app (or --archive PATH, or CUPID_RUNTIME_ARCHIVE).
Without one it falls back to Recall 1.3.0's prebuilt runtime, downloaded from Recall's DMG,
which lacks Cupid's patches and video support.
"""

let valued: Set<String> = ["data", "step", "archive", "wait", "lines", "name", "wine-debug", "fullscreen"]
let allowedFlags: Set<String> = ["help", "json", "verify", "hud", "no-hud", "no-wait", "yes", "repair",
                                 "accept-new-installer", "dxmt-info", "input-stats", "path"]

// MARK: output helpers

let stderrIsTTY = isatty(2) != 0
func say(_ s: String) { print(s); fflush(stdout) }
func warn(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func bytes(_ n: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file; return f.string(fromByteCount: n)
}
func progressPrinter(_ label: String) -> Downloader.Progress {
    let last = LockedInt()
    return { received, expected in
        let pct = expected.map { Int(Double(received) / Double(max($0, 1)) * 100) } ?? -1
        guard last.swap(pct) != pct else { return }
        let text = expected.map { "\(label): \(bytes(received)) of \(bytes($0)) (\(pct)%)" } ?? "\(label): \(bytes(received))"
        if stderrIsTTY { FileHandle.standardError.write(Data(("\r" + text + (pct == 100 ? "\n" : "")).utf8)) }
        else if pct % 10 == 0 { warn(text) }
    }
}
final class LockedInt: @unchecked Sendable {
    private let lock = NSLock(); private var v = Int.min
    func swap(_ n: Int) -> Int { lock.lock(); defer { lock.unlock() }; let o = v; v = n; return o }
}
func confirm(_ question: String) -> Bool {
    guard isatty(0) != 0 else { return false }
    print("\(question) [y/N] ", terminator: ""); fflush(stdout)
    guard let line = readLine() else { return false }
    return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
}
func fail(_ message: String, _ kind: CupidError.Kind = .usage) -> CupidError { CupidError(kind, message) }

// MARK: commands

struct CLI {
    let args: Arguments
    let paths: Paths

    func run() throws {
        switch args.command {
        case nil, "help": say(usage)
        case "setup": try setup()
        case "install-game": try installGame()
        case "play": try play()
        case "stop": try stop()
        case "status": try status()
        case "update": try update()
        case "logs": try logs()
        case "reset-graphics": try resetGraphics()
        case "uninstall": try uninstall()
        case "verify-runtime": try verifyRuntime()
        case let other?: throw fail("unknown command: \(other)\n\n\(usage)")
        }
    }

    // MARK: setup

    func setup() throws {
        let step = args.options["step"] ?? "all"
        guard ["runtime", "prefix", "taptap", "all"].contains(step) else {
            throw fail("--step must be runtime, prefix, taptap or all")
        }
        guard Rosetta.isInstalled else {
            throw fail("Rosetta 2 is not installed. Install it with: softwareupdate --install-rosetta --agree-to-license", .rosetta)
        }
        if step == "runtime" || step == "all" { try setupRuntime() }
        if step == "prefix" || step == "all" { try setupPrefix() }
        if step == "taptap" || step == "all" { try setupTapTap() }
        if step == "all" { say("Next: `cupid install-game` to download Heartopia through TapTap.") }
    }

    func setupRuntime() throws {
        let installer = RuntimeInstaller(paths: paths)
        let repair = args.has("repair")
        if installer.isPresent && !repair {
            let version = installer.installedVersion()
            guard version == paths.runtimeVersion else {
                throw fail("\(paths.runtime.path)/runtime.json names version \(version ?? "?"), expected \(paths.runtimeVersion). Run `cupid setup --step runtime --repair`.", .runtimeInvalid)
            }
            say("Runtime \(paths.runtimeVersion) is installed at \(paths.runtime.path)")
            let started = Date()
            let report = try installer.verify()
            guard report.ok else {
                throw fail("The installed runtime failed verification:\n  " + report.problems.prefix(20).joined(separator: "\n  ")
                           + "\nRun `cupid setup --step runtime --repair` to reinstall it.", .runtimeInvalid)
            }
            say("  \(report.checked) files match runtime.json (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
            try installer.verifyLoaderSignatures()
            say("  Wine loader signatures valid")
            let created = try installer.ensureGameModeBundle()
            say(created ? "  Created and signed \(GameModeBundle.relativePath)" : "  \(GameModeBundle.relativePath) present and valid (kept)")
            try AppState.update(paths) { $0.runtime = paths.runtimeVersion } // writes only if it changed
            say(created ? "Runtime ready." : "Runtime ready: nothing to do.")
            return
        }
        if repair { try SessionGuard.requireIdle(paths, to: "replace the runtime") }
        let archive: URL
        if let explicit = args.options["archive"] {
            archive = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        } else if let found = RuntimeInstaller.locateArchive(paths: paths) {
            archive = found
        } else {
            say("No bundled runtime.tar.gz found; falling back to Recall 1.3.0's prebuilt runtime, fetched from its DMG (no Cupid patches, no video)")
            archive = try installer.fetchArchiveFromDMG(progress: progressPrinter("Recall-1.3.0.dmg"), log: say)
        }
        say("Installing the runtime from \(archive.path)")
        try installer.install(archive: archive, replace: repair, log: { say("  " + $0) })
        try installer.verifyLoaderSignatures()
        say("  Wine loader signatures valid")
        try installer.ensureGameModeBundle()
        say("  \(GameModeBundle.relativePath) created, signed and verified")
        say("  wine --version: \(try Wine(paths: paths).version())")
        try AppState.update(paths) { $0.runtime = paths.runtimeVersion }
        Logs.append(paths, "setup: runtime \(paths.runtimeVersion) installed")
        say("Runtime ready.")
    }

    func setupPrefix() throws {
        guard RuntimeInstaller(paths: paths).installedVersion() == paths.runtimeVersion else {
            throw fail("The runtime is not installed. Run `cupid setup --step runtime` first.", .runtimeMissing)
        }
        let setup = PrefixSetup(paths: paths)
        let steps = setup.plan(state: AppState.load(paths))
        if steps.isEmpty {
            // Nothing is written, not even state.json: an adopted spike prefix stays byte-identical.
            say("Prefix up to date at \(paths.prefix.path): Windows 10, RetinaMode=N, \(RegistrySeeds.all.count - 1) game settings present, macOS fonts linked, no user-folder symlinks.")
            return
        }
        say("Prefix needs: " + steps.map(\.description).joined(separator: "; "))
        try SessionGuard.requireIdle(paths, to: "change the Wine prefix")
        try setup.apply(steps, log: { say("  " + $0) })
        say("Prefix ready.")
    }

    func setupTapTap() throws {
        guard PrefixSetup(paths: paths).exists else {
            throw fail("The prefix does not exist. Run `cupid setup --step prefix` first.", .prefixMissing)
        }
        if TapTapLauncher.isInstalled(paths) {
            say("TapTap launcher installed at \(paths.launcherExe.path)")
            try AppState.update(paths) { $0.taptapInstalled = true }
            return
        }
        let snapshot = SessionSnapshot.take(paths)
        if !snapshot.installer.isEmpty {
            say("The TapTap installer is already running.")
            say(TapTapInstaller.instructions)
        } else {
            try SessionGuard.requireIdle(paths, to: "start the TapTap installer")
            say("Downloading the TapTap Global installer")
            let check = try TapTapInstaller.download(paths, progress: progressPrinter("TapTap installer"))
            switch check {
            case .pinned:
                say("  \(TapTapInstaller.fileName): \(TapTapInstaller.bytes) bytes, sha256 matches the pin")
            case .missing:
                throw fail("The installer download is missing.", .download)
            case .changed(let size, let sha):
                say("TapTap updated its installer: \(size) bytes, sha256 \(sha) (expected \(TapTapInstaller.bytes) bytes, \(TapTapInstaller.sha256)).")
                let accepted = AppState.load(paths).acceptedInstallerSHA256 == sha
                guard accepted || args.has("accept-new-installer") || confirm("Run the new installer anyway?") else {
                    throw fail("Not running an installer that does not match the pin. Re-run with --accept-new-installer to proceed.", .installerChanged)
                }
                try AppState.update(paths) { $0.acceptedInstallerSHA256 = sha }
            }
            let pid = try TapTapInstaller.run(paths)
            Logs.append(paths, "setup: TapTap installer started (wine pid \(pid))")
            say(TapTapInstaller.instructions)
        }
        if args.has("no-wait") { say("Not waiting (--no-wait). Re-run `cupid setup --step taptap` to check."); return }

        let limit = TimeInterval(args.options["wait"].flatMap(Double.init) ?? 1800)
        say("Waiting up to \(Int(limit / 60)) min for the installer to finish…")
        let deadline = Date().addingTimeInterval(limit)
        while !TapTapLauncher.isInstalled(paths) {
            guard Date() < deadline else { throw fail("TapTap is still not installed. Re-run `cupid setup --step taptap` to keep waiting.", .timeout) }
            let snap = SessionSnapshot.take(paths)
            if snap.installer.isEmpty && !snap.isAlive {
                throw fail("The installer exited without installing TapTap (see \(Logs.installer(paths).path)).", .process)
            }
            Thread.sleep(forTimeInterval: 5)
        }
        say("TapTapGlobal.exe installed. Waiting for the installer to exit…")
        let exitDeadline = Date().addingTimeInterval(180)
        while !SessionSnapshot.take(paths).installer.isEmpty && Date() < exitDeadline { Thread.sleep(forTimeInterval: 2) }
        // VERIFY: the installer starts the launcher without the Electron flags (blank window). End
        // that session so `install-game` can start it properly.
        let snap = SessionSnapshot.take(paths)
        if snap.installer.isEmpty, snap.game == nil, snap.isAlive {
            say("Closing the launcher the installer opened (it needs Cupid's flags to render)")
            try Session.stop(paths: paths, log: Logs.stop(paths))
        }
        try AppState.update(paths) { $0.taptapInstalled = true }
        say("TapTap installed.")
    }

    // MARK: install-game

    func describe(_ state: GameInstall.State) -> String {
        switch state {
        case .notStarted: return "not started (no C:\\TapTapGlobal\\Apps\\231364 yet)"
        case .downloading(let p):
            if let total = p.totalBytes { return "downloading: \(bytes(p.bytesOnDisk)) of \(bytes(total)) (\(p.percent ?? 0)%)" }
            return "downloading: \(bytes(p.bytesOnDisk)) so far (total unknown until GameFileInfo.json appears)"
        case .incomplete(let c): return "files complete but \(c.md5Mismatch.count) of \(c.md5Checked) sampled md5 sums differ"
        case .installed(let c): return "installed: \(c.listed) files at their listed sizes, \(c.md5Checked) md5 sums sampled"
        }
    }

    func installGame() throws {
        guard TapTapLauncher.isInstalled(paths) else {
            throw fail("TapTap is not installed. Run `cupid setup --step taptap` first.", .launcherNotInstalled)
        }
        let state = GameInstall.state(paths)
        if case .installed = state {
            say("Heartopia: \(describe(state))")
            try AppState.update(paths) { $0.gameInstalled = true }
            return
        }
        say("Heartopia: \(describe(state))")
        if let pid = try TapTapLauncher.run(paths) {
            Logs.append(paths, "install-game: launcher started (wine pid \(pid))")
        } else {
            say("The TapTap launcher is already open.")
        }
        say(TapTapLauncher.downloadInstructions)
        if args.has("no-wait") { say("Not waiting (--no-wait). `cupid status` shows the progress."); return }
        let limit = args.options["wait"].flatMap(Double.init)
        let deadline = limit.map { Date().addingTimeInterval($0) }
        var lastLine = ""
        while true {
            let progress = GameInstall.state(paths, md5Sample: 0)
            if case .installed = progress {
                let final = GameInstall.state(paths)
                if case .installed = final {
                    say("Heartopia: \(describe(final))")
                    try AppState.update(paths) { $0.gameInstalled = true }
                    say("Close the TapTap launcher window, then run `cupid play`.")
                    return
                }
                say("Heartopia: \(describe(final)). Use the launcher's Repair/Verify, then re-run install-game.")
                return
            }
            let line = describe(progress)
            if line != lastLine { say("  " + line); lastLine = line }
            if let deadline, Date() >= deadline { say("Still downloading; re-run `cupid install-game` to keep following it."); return }
            if SessionSnapshot.take(paths).launcher.isEmpty {
                say("The TapTap launcher closed before the download finished. Re-run `cupid install-game`.")
                return
            }
            Thread.sleep(forTimeInterval: 10)
        }
    }

    // MARK: play / stop / update

    func play() throws {
        let state = AppState.load(paths)
        var options = GameLauncher.Options()
        options.hud = args.has("hud") ? true : args.has("no-hud") ? false : (state.hud ?? false)
        if args.has("dxmt-info") { options.dxmtInfoLog = true }
        options.wineDebug = args.options["wine-debug"]
        options.inputStats = args.has("input-stats")
        options.fullscreen = state.fullscreen
        if let value = args.options["fullscreen"] {
            guard let mode = FullscreenMode(argument: value) else {
                throw fail("--fullscreen takes notifications, fill, or space (got \(value))")
            }
            options.fullscreen = mode
        }
        if args.has("hud") || args.has("no-hud") { try AppState.update(paths) { $0.hud = options.hud } }
        let result = try GameLauncher(paths: paths).play(options, waitForWindow: !args.has("no-wait"), log: { say("  " + $0) })
        say("Started Heartopia (wine pid \(result.winePID)); log: \(result.log.path)")
        if let game = result.game {
            say("  game pid \(game.pid), executable \(game.path)")
            say(result.inGameModeBundle ? "  running from xdt.app (Game Mode eligible)" : "  WARNING: not running from xdt.app; Game Mode will not engage")
        }
        if let w = result.window { say("  window: \(w.owner) \(w.width)x\(w.height) at (\(w.x),\(w.y))") }
    }

    func stop() throws {
        let snap = SessionSnapshot.take(paths)
        guard snap.isAlive || !snap.processes.isEmpty else { say("No Cupid Wine session is running."); return }
        if let game = snap.game, !args.has("yes") {
            guard confirm("Heartopia is running (pid \(game.pid)). Stopping ends it immediately. Continue?") else {
                throw fail("Not stopped. Pass --yes to stop without asking.", .cancelled)
            }
        }
        say("Stopping the Wine session")
        try Session.stop(paths: paths, log: Logs.stop(paths))
        Logs.append(paths, "stop")
        let left = SessionSnapshot.take(paths).processes
        if left.isEmpty { say("No Wine processes left.") }
        else { say("Still running:\n" + left.map { "  \($0.pid) \($0.argv0 ?? $0.path)" }.joined(separator: "\n")) }
    }

    func update() throws {
        if let pid = try TapTapLauncher.run(paths) {
            Logs.append(paths, "update: launcher started (wine pid \(pid))")
            say("Opened the TapTap launcher. If it offers a Heartopia update, run it; close the launcher when done, then `cupid play`.")
        } else {
            say("The TapTap launcher is already open.")
        }
    }

    // MARK: status

    func status() throws {
        let report = StatusReport.gather(paths, verify: args.has("verify"))
        if args.has("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            say(String(decoding: try encoder.encode(report), as: UTF8.self))
            return
        }
        let r = report
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        say("Data:     \(r.dataRoot)")
        say("Rosetta:  \(r.rosetta ? "installed" : "MISSING")")
        var rt = r.runtime.installedVersion.map { "\($0)\($0 == r.runtime.expectedVersion ? "" : " (expected \(r.runtime.expectedVersion))")" } ?? "not installed"
        if let v = r.runtime.verified { rt += v ? ", verified" : ", VERIFICATION FAILED" }
        var bundle = r.runtime.gameModeBundle ? "present" : "missing"
        if let id = r.runtime.gameModeBundleIdentifier, id != GameModeBundle.identifier {
            bundle += " (identifier \(id); `cupid setup --step runtime` regenerates it)"
        }
        say("Runtime:  \(rt); xdt.app \(bundle)")
        for p in (r.runtime.problems ?? []).prefix(10) { say("          ! \(p)") }
        if r.prefix.exists {
            let seeds = r.prefix.pendingSeeds.isEmpty ? "all seeds present" : "pending seeds: \(r.prefix.pendingSeeds.joined(separator: ", "))"
            let fonts = r.prefix.missingFonts.isEmpty ? "fonts linked" : "missing fonts: \(r.prefix.missingFonts.joined(separator: ", "))"
            say("Prefix:   Windows 10 \(yn(r.prefix.windows10)), RetinaMode=\(r.prefix.retinaMode ?? "unset"), \(seeds), \(fonts)")
        } else {
            say("Prefix:   not created")
        }
        say("dxmt.conf: \(r.prefix.dxmtConfCurrent ? "current" : "differs from the template (rewritten at next play)")")
        var tt = r.taptap.launcherInstalled ? "launcher installed" : "launcher not installed"
        if r.taptap.installerDownloaded { tt += ", installer downloaded" + (r.taptap.installerPinned.map { $0 ? " (pinned hash)" : " (HASH DIFFERS)" } ?? "") }
        say("TapTap:   \(tt)")
        var g = r.game.state
        if let total = r.game.totalBytes, let have = r.game.bytesOnDisk { g += ": \(bytes(have)) of \(bytes(total)) (\(r.game.percent ?? 0)%)" }
        else if let have = r.game.bytesOnDisk { g += ": \(bytes(have))" }
        if let listed = r.game.filesListed { g += " (\(listed) files listed, \(r.game.missing ?? 0) missing, \(r.game.wrongSize ?? 0) wrong size, \(r.game.signedPE ?? 0) signed PE" + (r.game.md5Checked.map { $0 > 0 ? ", \($0) md5 sampled, \(r.game.md5Mismatch ?? 0) differ" : "" } ?? "") + ")" }
        say("Game:     \(g)")
        if let v = r.game.version { say("          version \(v)" + (r.game.build.map { " (build \($0))" } ?? "")) }
        if r.session.alive {
            say("Session:  alive (wineserver \(r.session.wineserverPIDs.map(String.init).joined(separator: ", ")))")
            if let game = r.session.game {
                say("          Heartopia running: pid \(game.pid)\(r.session.gameInModeBundle ? ", from xdt.app (Game Mode)" : ", NOT from xdt.app")")
                if let w = r.session.window { say("          window: \(w.owner) \(w.width)x\(w.height)") }
            }
            if r.session.launcherRunning { say("          TapTap launcher open") }
            if r.session.installerRunning { say("          TapTap installer open") }
            for p in r.session.programs.prefix(20) { say("          \(p)") }
        } else {
            say("Session:  none")
        }
        say("State:    " + String(decoding: (try? JSONEncoder().encode(r.state)) ?? Data(), as: UTF8.self))
    }

    // MARK: logs / reset / uninstall / verify

    func logs() throws {
        if args.has("path") { say(paths.logs.path); return }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: paths.logs.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        say("Logs in \(paths.logs.path):")
        for name in names {
            let attrs = try? fm.attributesOfItem(atPath: paths.logs.appendingPathComponent(name).path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            say("  \(name)  \(bytes(size))")
        }
        let name = args.options["name"] ?? "game.log"
        guard !name.contains("/") else { throw fail("--name takes a file name in the logs folder") }
        let lines = Int(args.options["lines"] ?? "40") ?? 40
        let url = paths.logs.appendingPathComponent(name)
        guard let text = Logs.tail(url, lines: lines) else { say("(no \(name))"); return }
        say("--- last \(lines) lines of \(name)")
        say(text)
    }

    func resetGraphics() throws {
        guard PrefixSetup(paths: paths).exists else { throw fail("The prefix does not exist.", .prefixMissing) }
        try SessionGuard.requireIdle(paths, to: "reset the graphics settings")
        say("Re-applying \(RegistrySeeds.all.count) registry seeds")
        try PrefixSetup(paths: paths).apply(RegistrySeeds.all.map(PrefixSetup.Step.seed), log: { say("  " + $0) })
        Logs.append(paths, "reset-graphics")
        say("Graphics settings reset.")
    }

    func uninstall() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.dataRoot.path) else { say("Nothing to remove: \(paths.dataRoot.path) does not exist."); return }
        try SessionGuard.requireIdle(paths, to: "uninstall")
        if !args.has("yes") {
            guard confirm("Move \(paths.dataRoot.path) (runtime, Wine prefix with TapTap and Heartopia, logs) to the Trash?") else {
                throw fail("Not removed. Pass --yes to skip the question.", .cancelled)
            }
        }
        var trashed: NSURL?
        try fm.trashItem(at: paths.dataRoot, resultingItemURL: &trashed)
        say("Moved to the Trash: \(trashed?.path ?? paths.dataRoot.path)")
    }

    func verifyRuntime() throws {
        if let archive = args.options["archive"] {
            let url = URL(fileURLWithPath: (archive as NSString).expandingTildeInPath)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("cupid-verify-\(getpid())")
            defer { try? FileManager.default.removeItem(at: staging) }
            let report = try RuntimeInstaller(paths: paths).extractAndVerify(archive: url, into: staging, log: { say($0) })
            try printReport(report, url.path)
            return
        }
        let dir = args.positionals.first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? paths.runtime
        let manifest = try RuntimeManifest.load(dir.appendingPathComponent("runtime.json"))
        try printReport(manifest.verify(root: dir), dir.path)
    }

    func printReport(_ report: RuntimeManifest.Report, _ what: String) throws {
        guard report.ok else {
            for p in report.problems.prefix(50) { warn(p) }
            throw fail("FAIL: \(report.problems.count) problem(s) in \(what)", .runtimeInvalid)
        }
        say("OK: \(report.checked) files match runtime.json (\(report.version))")
    }
}

// MARK: entry point

do {
    let args = try Arguments(Array(CommandLine.arguments.dropFirst()), valued: valued, allowedFlags: allowedFlags)
    if args.has("help") { say(usage); exit(0) }
    let paths = Paths.resolve(dataOverride: args.options["data"])
    try CLI(args: args, paths: paths).run()
} catch let error as Arguments.UsageError {
    warn("error: \(error)\n\n\(usage)")
    exit(2)
} catch let error as CupidError {
    warn("error: \(error.message)")
    switch error.kind {
    case .usage: exit(2)
    case .sessionAlive: exit(3)
    case .cancelled: exit(4)
    default: exit(1)
    }
} catch {
    warn("error: \(error.localizedDescription)")
    exit(1)
}
