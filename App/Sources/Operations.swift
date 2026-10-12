import AppKit
import CupidCore

/// The long, synchronous setup steps the app runs off the main thread. They mirror
/// `cupid setup` (Sources/cupid/main.swift) step for step.
enum Operations {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; return f.string(fromByteCount: n)
    }

    /// Technical progress lines (file names, versions, registry keys) go to the log, not the window.
    static func detail(_ paths: Paths) -> @Sendable (String) -> Void {
        { Logs.append(paths, "app: " + $0) }
    }

    static func byteProgress(_ r: Reporter, _ label: String) -> Downloader.Progress {
        { received, expected in
            if let expected, expected > 0 {
                let fraction = Double(received) / Double(expected)
                r.line("\(label): \(bytes(received)) of \(bytes(expected)) (\(Int(fraction * 100))%)")
                r.fraction(fraction)
            } else {
                r.line("\(label): \(bytes(received))")
            }
        }
    }

    /// `setup --step runtime` (with `replace`: `--repair`).
    static func installRuntimeIfNeeded(_ paths: Paths, _ r: Reporter, replace: Bool) throws {
        guard Rosetta.isInstalled else {
            throw CupidError(.rosetta, "Rosetta 2 is not installed.")
        }
        let installer = RuntimeInstaller(paths: paths)
        if installer.isPresent && !replace {
            let version = installer.installedVersion()
            guard version == paths.runtimeVersion else {
                throw CupidError(.runtimeInvalid, "The installed runtime is version \(version ?? "?"), expected \(paths.runtimeVersion). Use Repair to reinstall it.")
            }
            r.line("Checking the game runtime")
            try installer.ensureGameModeBundle()
            try AppState.update(paths) { $0.runtime = paths.runtimeVersion }
            return
        }
        if replace { try SessionGuard.requireIdle(paths, to: "replace the runtime") }
        let archive: URL
        if let found = RuntimeInstaller.locateArchive(paths: paths) {
            archive = found
        } else {
            r.line("Downloading the game runtime")
            archive = try installer.fetchArchiveFromDMG(progress: byteProgress(r, "Game runtime"), log: detail(paths))
            r.fraction(nil)
        }
        try r.checkCancelled()
        r.line("Installing the game runtime")
        try installer.install(archive: archive, replace: replace, log: detail(paths))
        r.line("Checking the game runtime")
        try installer.verifyLoaderSignatures()
        try installer.ensureGameModeBundle()
        Logs.append(paths, "app: wine --version: \(try Wine(paths: paths).version())")
        try AppState.update(paths) { $0.runtime = paths.runtimeVersion }
        Logs.append(paths, "app: runtime \(paths.runtimeVersion) installed")
    }

    /// `setup --step prefix`.
    static func setUpPrefixIfNeeded(_ paths: Paths, _ r: Reporter) throws {
        let setup = PrefixSetup(paths: paths)
        let steps = setup.plan(state: AppState.load(paths))
        guard !steps.isEmpty else { r.line("Windows environment up to date"); return }
        try SessionGuard.requireIdle(paths, to: "change the Wine prefix")
        r.line(setup.exists ? "Updating the Windows environment" : "Creating the Windows environment")
        try setup.apply(steps, log: detail(paths))
    }

    /// `setup --repair` plus a full md5 check of the game. Returns a summary.
    static func repair(_ paths: Paths, _ r: Reporter) throws -> String {
        try SessionGuard.requireIdle(paths, to: "repair")
        var summary: [String] = []
        try installRuntimeIfNeeded(paths, r, replace: true)
        Logs.append(paths, "app: repair: runtime \(paths.runtimeVersion) reinstalled and verified")
        summary.append("Game runtime reinstalled.")
        try r.checkCancelled()
        try setUpPrefixIfNeeded(paths, r)
        summary.append("Windows environment checked.")
        try r.checkCancelled()

        guard let info = try? GameFileInfo.load(paths.gameFileInfo) else {
            summary.append("Heartopia is not downloaded yet; no game files to check.")
            return summary.joined(separator: " ")
        }
        r.line("Checking file sizes of \(info.files.count) game files")
        r.fraction(0)
        let check = GameInstall.verify(paths, info: info, md5Sample: .max, maxSampleBytes: .max,
                                       progress: { done, total in
                                           if done % 25 == 0 || done == total {
                                               r.line("Checking game files: \(done) of \(total)")
                                               r.fraction(Double(done) / Double(max(total, 1)))
                                           }
                                       },
                                       isCancelled: { r.isCancelled })
        try r.checkCancelled()
        if check.ok {
            Logs.append(paths, "app: repair: all \(check.listed) files match GameFileInfo.json (\(check.md5Checked) md5 sums checked, \(check.signedPE.count) signed executables accepted by size)")
            summary.append("All \(check.listed) game files are intact.")
            try AppState.update(paths) { $0.gameInstalled = true }
        } else {
            let bad = check.missing.count + check.wrongSize.count + check.md5Mismatch.count
            Logs.append(paths, "app: repair: \(check.missing.count) missing, \(check.wrongSize.count) wrong size, \(check.md5Mismatch.count) md5 differ")
            summary.append("\(bad) game file(s) are missing or damaged. Use Update Game and TapTap's repair to fetch them again.")
            Logs.append(paths, "app: repair found damaged files: " + (check.missing + check.wrongSize + check.md5Mismatch).prefix(50).joined(separator: ", "))
        }
        Logs.append(paths, "app: repair done")
        return summary.joined(separator: " ")
    }

    /// Brings a Wine program's window to the front: every 0.5 s, activates the processes `pick`
    /// selects from a fresh snapshot, until one of them has a window on screen (activated once
    /// more) or `timeout` passes. Returns true once a window is on screen.
    static func bringToFront(_ paths: Paths, timeout: TimeInterval,
                             _ pick: @escaping @Sendable (SessionSnapshot) -> [WineProcess]) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let pids = pick(SessionSnapshot.take(paths)).map(\.pid)
            let window = pids.isEmpty ? nil
                : WindowInfo.list(pids: Set(pids)).first { $0.layer == 0 && $0.width > 1 && $0.height > 1 }
            activate(window.map { [$0.pid] } ?? pids)
            if window != nil { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Activates the apps of `pids` (Wine programs become regular apps once their window
    /// server connection is up; before that there is nothing to activate).
    static func activate(_ pids: [Int32]) {
        guard !pids.isEmpty else { return }
        DispatchQueue.main.async {
            for pid in pids {
                guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                NSApp.yieldActivation(to: app)
                app.activate(options: [.activateAllWindows])
            }
        }
    }
}
