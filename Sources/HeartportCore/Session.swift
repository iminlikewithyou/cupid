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

/// The live processes of Heartport's runtimes at one moment.
public struct SessionSnapshot: Sendable {
    public let processes: [WineProcess]
    public let runtimesDir: String
    public let wineserverPath: String

    public init(processes: [WineProcess], runtimesDir: String, wineserverPath: String) {
        self.processes = processes; self.runtimesDir = runtimesDir; self.wineserverPath = wineserverPath
    }

    /// Every process whose binary is inside `<data>/runtime/` (any version: they share the prefix).
    public static func take(_ paths: Paths) -> SessionSnapshot {
        let dir = LiveProcesses.canonical(paths.runtimesDir.path)
        let entries = LiveProcesses.allPIDs().compactMap { pid -> WineProcess? in
            guard let path = LiveProcesses.path(pid), path.hasPrefix(dir + "/") else { return nil }
            return WineProcess(pid: pid, path: path, argv0: LiveProcesses.argv0(pid))
        }
        return SessionSnapshot(processes: entries, runtimesDir: dir, wineserverPath: LiveProcesses.canonical(paths.wineserver.path))
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
    public var installer: [WineProcess] {
        processes.filter { $0.programName?.hasPrefix("taptap_global_pc_setup") == true }
    }
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
        list(pids: [pid]).first { $0.layer == 0 && $0.width > 1 && $0.height > 1 }
    }
}

public enum Session {
    /// `wineserver -k` then `wineserver -w`, under the full environment.
    public static func stop(paths: Paths, log: URL) throws {
        let wine = Wine(paths: paths)
        _ = try? wine.wineserver(["-k"], log: log, timeout: 30)
        try wine.wineserver(["-w"], log: log, timeout: 60)
        // Clients normally exit with their server, but a game under Rosetta has been seen to
        // outlive it (still running, parent 1). Finish them: SIGTERM, then SIGKILL.
        for signal in [SIGTERM, SIGKILL] {
            let leftovers = SessionSnapshot.take(paths).processes
            if leftovers.isEmpty { return }
            for process in leftovers { kill(process.pid, signal) }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !SessionSnapshot.take(paths).processes.isEmpty {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
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
