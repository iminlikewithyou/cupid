import Foundation

public enum SessionGuard {
    /// Throws when a wineserver of our runtimes is alive: the registry, dxmt.conf and the
    /// prefix must not be changed under a running session (the game would overwrite them, or
    /// lose its own changes).
    public static func requireIdle(_ paths: Paths, to action: String) throws {
        let snapshot = SessionSnapshot.take(paths)
        guard snapshot.isAlive else { return }
        let servers = snapshot.wineservers.map { String($0.pid) }.joined(separator: ", ")
        var what = "A Cupid Wine session is running (wineserver pid \(servers))"
        if let game = snapshot.game { what += "; Heartopia is running (pid \(game.pid))" }
        else if !snapshot.launcher.isEmpty { what += "; the TapTap launcher is open" }
        else if !snapshot.installer.isEmpty { what += "; the TapTap installer is open" }
        throw CupidError(.sessionAlive, "\(what). Refusing to \(action) while it is alive. Quit the game (or run `cupid stop`) and try again.")
    }
}

/// Builds and maintains the Wine prefix (docs/PHASE2.md "Prefix setup").
public struct PrefixSetup: Sendable {
    public enum Step: Sendable, Equatable, CustomStringConvertible {
        case wineboot(reason: String)
        case winecfgWin10
        case seed(RegistrySeed)
        case replaceLinks([String])
        case fontLinks([String])
        /// Registry value names (`WindowsFonts.Link.registryValue`) to add under HKLM.
        case fontRegistry([String])

        public var description: String {
            switch self {
            case .wineboot(let reason): "wineboot.exe -u -r (\(reason))"
            case .winecfgWin10: "winecfg -v win10"
            case .seed(let s): "reg add \(s.hive.rawValue)\\\(s.key) \(s.name)"
            case .replaceLinks(let l): "replace \(l.count) symlink(s) in drive_c/users"
            case .fontLinks(let f): "link \(f.count) macOS font(s) into windows/Fonts"
            case .fontRegistry(let f): "register \(f.count) font(s) in HKLM\\\(RegistrySeeds.fontsKey)"
            }
        }
    }

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var exists: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: paths.systemReg.path) && fm.fileExists(atPath: paths.userReg.path)
            && fm.fileExists(atPath: paths.driveC.path)
    }

    /// Symlinks directly inside `drive_c/users/*/` (relative to drive_c/users).
    public func userLinks() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for user in (try? fm.contentsOfDirectory(atPath: paths.usersDir.path)) ?? [] {
            let dir = paths.usersDir.appendingPathComponent(user)
            guard (try? fm.destinationOfSymbolicLink(atPath: dir.path)) == nil else { continue }
            for item in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                if (try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(item).path)) != nil {
                    out.append("\(user)/\(item)")
                }
            }
        }
        return out.sorted()
    }

    /// What `apply` would do. Empty means the prefix is up to date. Reads files only.
    public func plan(state: AppState, forceSeeds: Bool = false) -> [Step] {
        var steps: [Step] = []
        let exists = self.exists
        if !exists {
            steps.append(.wineboot(reason: "create"))
        } else if let booted = state.prefixRuntime ?? state.runtime, booted != paths.runtimeVersion {
            steps.append(.wineboot(reason: "runtime changed from \(booted)"))
        }
        let system = exists ? RegFile(contentsOf: paths.systemReg) : nil
        if !exists || !RegistrySeeds.isWindows10(system) {
            steps.append(.winecfgWin10)
        }
        let user = exists ? RegFile(contentsOf: paths.userReg) : nil
        steps += RegistrySeeds.pending(in: user, force: forceSeeds).map(Step.seed)
        let links = exists ? userLinks() : []
        if !links.isEmpty || !exists { steps.append(.replaceLinks(links)) }
        let fonts = WindowsFonts.pending(in: paths.windowsFonts)
        if !fonts.isEmpty { steps.append(.fontLinks(fonts.map(\.name))) }
        let unregistered = WindowsFonts.unregistered(in: paths.windowsFonts, systemReg: system)
        if !unregistered.isEmpty { steps.append(.fontRegistry(unregistered.map(\.registryValue))) }
        return steps
    }

    /// Run `steps` in order. Refuses while a session is alive.
    public func apply(_ steps: [Step], log: (String) -> Void = { _ in }) throws {
        guard !steps.isEmpty else { return }
        try SessionGuard.requireIdle(paths, to: "change the Wine prefix")
        try paths.createLayout()
        let wine = Wine(paths: paths)
        let wlog = Logs.winePrefix(paths)
        func check(_ status: Int32, _ what: String) throws {
            guard status == 0 else { throw CupidError(.process, "\(what) exited \(status) (see \(wlog.path))") }
        }
        for step in steps {
            log(step.description)
            Logs.append(paths, "prefix: \(step)")
            switch step {
            case .wineboot:
                try check(try wine.run(["wineboot.exe", "-u", "-r"], log: wlog, timeout: 180), "wineboot")
                try check(try wine.wineserver(["-w"], log: wlog, timeout: 60), "wineserver -w")
            case .winecfgWin10:
                try check(try wine.run(["winecfg", "-v", "win10"], log: wlog, timeout: 60), "winecfg -v win10")
            case .seed(let seed):
                try check(try wine.run(seed.regAddArguments, log: wlog, timeout: 60), "reg add \(seed.name)")
            case .replaceLinks:
                for rel in userLinks() {
                    let url = paths.usersDir.appendingPathComponent(rel)
                    log("  \(rel) -> \((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "?"): replaced")
                    try FileManager.default.removeItem(at: url)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                }
            case .fontLinks:
                for link in try WindowsFonts.create(in: paths.windowsFonts) {
                    log("  windows/Fonts/\(link.name) -> \(link.source)")
                }
            case .fontRegistry(let values):
                for link in WindowsFonts.all where values.contains(link.registryValue) {
                    // Exits 1 when Wine has no such record; that is the usual case.
                    _ = try wine.run(link.staleExternalDeleteArguments, log: wlog, timeout: 60)
                    try check(try wine.run(link.registrySeed.regAddArguments, log: wlog, timeout: 60), "reg add \(link.registryValue)")
                    log("  \(link.registryValue) = \(link.name)")
                }
            }
        }
        // Let the server exit so user.reg / system.reg are flushed, then confirm.
        try check(try wine.wineserver(["-w"], log: wlog, timeout: 60), "wineserver -w")
        try AppState.update(paths) { $0.prefix = "created"; $0.prefixRuntime = paths.runtimeVersion }
        let remaining = plan(state: AppState.load(paths)).filter { if case .replaceLinks = $0 { return false }; return true }
        guard remaining.isEmpty else {
            throw CupidError(.process, "Prefix setup finished but these steps are still pending: \(remaining.map(\.description).joined(separator: "; "))")
        }
    }
}
