import Darwin
import Foundation

/// Runs child processes. Wine is only ever started through `Wine`, which supplies the full
/// launch environment; this type is environment-agnostic.
public enum ProcessRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    /// Run to completion, capturing output. For short helpers (codesign, hdiutil, tar).
    @discardableResult
    public static func capture(_ executable: String, _ arguments: [String],
                               environment: [String: String]? = nil, cwd: URL? = nil,
                               timeout: TimeInterval = 600) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let outData = Locked(Data()), errData = Locked(Data())
        let group = DispatchGroup()
        try process.run()
        let outReader = out.fileHandleForReading, errReader = err.fileHandleForReading
        group.enter()
        DispatchQueue.global().async { let d = outReader.readDataToEndOfFile(); outData.withLock { $0 = d }; group.leave() }
        group.enter()
        DispatchQueue.global().async { let d = errReader.readDataToEndOfFile(); errData.withLock { $0 = d }; group.leave() }
        try wait(process, timeout: timeout, what: executable)
        group.wait()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: outData.current, as: UTF8.self),
                      stderr: String(decoding: errData.current, as: UTF8.self))
    }

    /// Run to completion with stdout and stderr appended to `log`.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String],
                           environment: [String: String], cwd: URL? = nil,
                           log: URL, timeout: TimeInterval) throws -> Int32 {
        let handle = try appendHandle(log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        try wait(process, timeout: timeout, what: ([executable] + arguments).joined(separator: " "))
        return process.terminationStatus
    }

    private static func wait(_ process: Process, timeout: TimeInterval, what: String) throws {
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if !process.isRunning { return }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw MactopiaError(.timeout, "Timed out after \(Int(timeout)) s: \(what)")
        }
    }

    static func appendHandle(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    /// Start a long-lived process in its own session (it survives the CLI and the terminal),
    /// stdin from /dev/null, stdout and stderr appended to `log`. Returns its pid.
    public static func spawnDetached(_ executable: String, _ arguments: [String],
                                     environment: [String: String], cwd: URL, log: URL) throws -> pid_t {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        guard rc == 0 else {
            throw MactopiaError(.process, "Could not start \(executable): \(String(cString: strerror(rc)))")
        }
        // Reap it whenever it exits so a long-lived host (the app) leaves no zombie.
        let child = pid
        Thread.detachNewThread { var status: Int32 = 0; waitpid(child, &status, 0) }
        return pid
    }
}
