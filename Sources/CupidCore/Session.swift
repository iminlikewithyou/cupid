import CoreGraphics
import Darwin
import Foundation

/// A process started from one of our runtimes.
public struct WineProcess: Sendable, Equatable, Codable {
    public let pid: Int32
    /// Resolved path of the binary (proc_pidpath).
    public let path: String
    /// argv[0]; Wine keeps the Windows program's path here.
    public let argv0: String?

    public init(pid: Int32, path: String, argv0: String?) { self.pid = pid; self.path = path; self.argv0 = argv0 }

    /// Lower-cased last component of argv[0], with Windows or Unix separators.
    public var programName: String? {
        guard let argv0 else { return nil }
        return argv0.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map { $0.lowercased() }
    }
}

/// The live processes of Cupid's runtimes at one moment.
public struct SessionSnapshot: Sendable {
    public let processes: [WineProcess]
    public let runtimesDir: String
    public let wineserverPath: String
    /// Unix directories an installer runs from (`<data>/downloads`, `<data>/tmp`), canonical.
    public let installerDirs: [String]

    public init(processes: [WineProcess], runtimesDir: String, wineserverPath: String, installerDirs: [String] = []) {
        self.processes = processes; self.runtimesDir = runtimesDir; self.wineserverPath = wineserverPath
        self.installerDirs = installerDirs
    }

    /// Every process whose binary is inside `<data>/runtime/` (any version: they share the
    /// prefix), plus every process CrossOver's loader re-executed from its cache
    /// (`<darwin user temp>/winetemp-*/<exe>`, see `LoaderCache`) when that cache entry's
    /// `ntdll.so` link resolves into `<data>/runtime/`. Every Windows program except the game
    /// (which runs from xdt.app inside the runtime) runs from that cache.
    public static func take(_ paths: Paths, loaderCacheDir: URL? = LoaderCache.darwinUserTempDir()) -> SessionSnapshot {
        let dir = LiveProcesses.canonical(paths.runtimesDir.path)
        let cache = loaderCacheDir.map { LiveProcesses.canonical($0.path) }
        var cacheEntryIsOurs: [String: Bool] = [:]
        func isOurs(_ path: String) -> Bool {
            if path.hasPrefix(dir + "/") { return true }
            guard let cache, path.hasPrefix(cache + "/winetemp-") else { return false }
            let rest = path.dropFirst(cache.count + 1)
            guard let slash = rest.firstIndex(of: "/") else { return false }
            let entry = cache + "/" + rest[..<slash]
            if let known = cacheEntryIsOurs[entry] { return known }
            let ours = LoaderCache.entry(URL(fileURLWithPath: entry, isDirectory: true), resolvesInto: dir)
            cacheEntryIsOurs[entry] = ours
            return ours
        }
        let entries = LiveProcesses.allPIDs().compactMap { pid -> WineProcess? in
            guard let path = LiveProcesses.path(pid), isOurs(path) else { return nil }
            return WineProcess(pid: pid, path: path, argv0: LiveProcesses.argv0(pid))
        }
        return SessionSnapshot(processes: entries, runtimesDir: dir, wineserverPath: LiveProcesses.canonical(paths.wineserver.path),
                               installerDirs: [paths.downloads, paths.tmp].map { LiveProcesses.canonical($0.path) })
    }

    /// wineserver processes of any of our runtimes (the session is alive while one runs).
    public var wineservers: [WineProcess] {
        processes.filter { $0.path == wineserverPath || ($0.path.hasSuffix("/bin/wineserver")) }
    }
    public var isAlive: Bool { !wineservers.isEmpty }

    public func running(_ program: String) -> [WineProcess] {
        let want = program.lowercased()
        return processes.filter { $0.programName == want }
    }
    public var game: WineProcess? { running(Game.exeName).first }
    public var launcher: [WineProcess] { running(Game.launcherExeName) }
    /// The TapTap installer. It runs as several processes in turn (language choice, install,
    /// "Installation complete"): the downloaded exe, or any program started from the
    /// downloads folder, Cupid's Unix temp folder, or the Windows temp folder.
    public var installer: [WineProcess] {
        processes.filter { p in
            guard let name = p.programName, name.hasSuffix(".exe"), !isWineOrGame(p) else { return false }
            if name.hasPrefix("taptap_global_pc_setup") { return true }
            let argv0 = (p.argv0 ?? "").replacingOccurrences(of: "\\", with: "/").lowercased()
            if argv0.contains("/appdata/local/temp/") || argv0.contains("/windows/temp/") { return true }
            return installerDirs.contains { argv0.hasPrefix($0.lowercased() + "/") }
        }
    }

    /// Wine's own background programs: never a sign that something the user started is open.
    public static let servicePrograms: Set<String> = [
        "services.exe", "rpcss.exe", "winemenubuilder.exe", "explorer.exe", "plugplay.exe",
        "svchost.exe", "conhost.exe", "winedevice.exe", "wineboot.exe", "start.exe",
    ]

    /// wineserver, the bare loader, Wine's services, the game, its crash handler, or TapTap.
    func isWineOrGame(_ p: WineProcess) -> Bool {
        if p.path == wineserverPath || p.path.hasSuffix("/bin/wineserver") { return true }
        guard let name = p.programName else { return true }
        if !name.hasSuffix(".exe") { return true } // the wine loader or preloader itself
        return Self.servicePrograms.contains(name) || name == Game.exeName
            || name == "unitycrashhandler64.exe" || name == Game.launcherExeName.lowercased()
    }

    /// Windows programs other than Wine's services, the game, and TapTap (an installer stage,
    /// a redistributable, ...).
    public var otherPrograms: [WineProcess] { processes.filter { !isWineOrGame($0) } }
    /// Windows programs (argv[0] looks like `C:\...`), for display.
    public var windowsPrograms: [WineProcess] {
        processes.filter { ($0.argv0 ?? "").range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil }
    }
}

/// libproc / sysctl access (re-implemented after MacGames' Status.swift; not copied).
public enum LiveProcesses {
    public static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(pids.prefix(Int(n))).filter { $0 > 0 } : []
    }

    public static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return canonical(String(decoding: bytes, as: UTF8.self))
    }

    /// argv[0] from KERN_PROCARGS2: argc, exec path, NUL padding, then argv[0].
    public static func argv0(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseArgv0(Array(buffer.prefix(size)))
    }

    public static func parseArgv0(_ buffer: [UInt8]) -> String? {
        var i = MemoryLayout<Int32>.size
        while i < buffer.count, buffer[i] != 0 { i += 1 }
        while i < buffer.count, buffer[i] == 0 { i += 1 }
        var j = i
        while j < buffer.count, buffer[j] != 0 { j += 1 }
        return i < j ? String(decoding: buffer[i..<j], as: UTF8.self) : nil
    }

    /// When the process started (proc_pidinfo PROC_PIDTBSDINFO).
    public static func startTime(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// An on-screen window (CGWindowList). Titles need Screen Recording permission; owner,
/// pid and bounds do not.
public struct WindowInfo: Sendable, Codable, Equatable {
    public let pid: Int32
    public let owner: String
    public let title: String
    public let layer: Int
    public let x: Int, y: Int, width: Int, height: Int

    public static func list(pids: Set<Int32>? = nil) -> [WindowInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.compactMap { w in
            let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            if let pids, !pids.contains(pid) { return nil }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            func n(_ k: String) -> Int { (b[k] as? NSNumber)?.intValue ?? 0 }
            return WindowInfo(pid: pid, owner: w[kCGWindowOwnerName as String] as? String ?? "",
                              title: w[kCGWindowName as String] as? String ?? "",
                              layer: (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                              x: n("X"), y: n("Y"), width: n("Width"), height: n("Height"))
        }
    }

    /// The game's window: owned by the xdt.exe process (owner name "Heartopia", the xdt.app loader).
    public static func game(pid: Int32) -> WindowInfo? {
        list(pids: [pid]).first(where: \.isOnScreenWindow)
    }

    /// A normal-level window larger than a placeholder.
    public var isOnScreenWindow: Bool { layer == 0 && width > 1 && height > 1 }
}

extension SessionSnapshot {
    /// The installer's processes (one per stage: language choice, install, "Installation
    /// complete") that have an on-screen window in `windows` and are not in `done`, in snapshot
    /// order: the stages still to bring to the front, once each.
    public func installerPIDsToActivate(windows: [WindowInfo], done: Set<Int32>) -> [Int32] {
        let shown = Set(windows.filter(\.isOnScreenWindow).map(\.pid))
        return installer.map(\.pid).filter { shown.contains($0) && !done.contains($0) }
    }
}

public enum Session {
    /// Ends the session quickly, logging each step with its duration to `log`: TapTap's
    /// processes first (SIGTERM, SIGKILL after 2 s; its Electron processes do not wait for a
    /// graceful exit), then `wineserver -k`, a direct signal to the server if it is still there,
    /// then any client that outlived the server.
    public static func stop(paths: Paths, log: URL) throws {
        let started = Date()
        func note(_ text: String) {
            Logs.append(to: log, String(format: "stop: %@ (%.1f s)", text, Date().timeIntervalSince(started)))
        }
        let before = SessionSnapshot.take(paths)
        note("begin; \(before.processes.count) processes: " + before.processes.map { $0.programName ?? "?" }.joined(separator: ", "))
        let launcher = before.launcher.map(\.pid)
        if !launcher.isEmpty {
            let killed = terminate(launcher, grace: 2)
            note("TapTap ended" + (killed > 0 ? " (\(killed) killed after 2 s)" : ""))
        }
        // Ask the server to quit, then make sure of it. `wineserver -k` has been seen to hang
        // for its whole timeout, with the server surviving, after TapTap's Electron processes
        // were force-ended (2026-10-12, fresh run 3); so the server pid is signalled directly
        // if it is still there, and the wait polls the process list instead of `wineserver -w`.
        let wine = Wine(paths: paths)
        var servers = SessionSnapshot.take(paths).wineservers.map(\.pid)
        if !servers.isEmpty {
            _ = try? wine.wineserver(["-k"], log: log, timeout: 3)
            note("wineserver -k")
            servers = servers.filter { kill($0, 0) == 0 }
            if !servers.isEmpty {
                let killed = terminate(servers, grace: 2)
                note("wineserver signalled directly (\(servers.count), \(killed) killed)")
            }
            guard waitForExit(paths: paths, timeout: 15) else {
                throw CupidError(.process, "The previous session did not end.")
            }
            note("wineserver gone")
        }
        // Clients normally exit with their server, but a game under Rosetta has been seen to
        // outlive it (still running, parent 1). Finish them: SIGTERM, then SIGKILL.
        let leftovers = SessionSnapshot.take(paths).processes.map(\.pid)
        if !leftovers.isEmpty {
            let killed = terminate(leftovers, grace: 5)
            note("\(leftovers.count) leftover processes ended (\(killed) killed)")
        }
        note("done")
    }

    /// SIGTERM to `pids`, then SIGKILL to those still alive after `grace` seconds; waits up to
    /// 2 s more for them to go. Returns how many needed SIGKILL.
    @discardableResult
    public static func terminate(_ pids: [Int32], grace: TimeInterval) -> Int {
        func alive() -> [Int32] { pids.filter { kill($0, 0) == 0 } }
        for pid in pids { kill(pid, SIGTERM) }
        var deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, !alive().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        let stubborn = alive()
        for pid in stubborn { kill(pid, SIGKILL) }
        deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !alive().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        return stubborn.count
    }

    /// Wait until no wineserver of our runtimes is alive.
    public static func waitForExit(paths: Paths, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !SessionSnapshot.take(paths).isAlive { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return !SessionSnapshot.take(paths).isAlive
    }
}

public enum Rosetta {
    /// Rosetta 2 is installed (its runtime is present).
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }
}
