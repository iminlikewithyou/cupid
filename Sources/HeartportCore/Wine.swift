import Foundation

/// The only way Heartport starts `wine` or `wineserver`: always with the full launch
/// environment (WINEPREFIX among it), so a stray `~/.wine` can never appear.
public struct Wine: Sendable {
    public let paths: Paths
    public let options: LaunchEnvironment.Options
    public let inherited: [String: String]

    public init(paths: Paths, options: LaunchEnvironment.Options = .init(),
                inherited: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.options = options
        self.inherited = inherited
    }

    public var environment: [String: String] {
        LaunchEnvironment.build(paths: paths, options: options, inherited: inherited)
    }

    private func preflight() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: paths.wine.path), fm.isExecutableFile(atPath: paths.wineserver.path) else {
            throw HeartportError(.runtimeMissing, "The runtime is not installed at \(paths.runtime.path). Run `heartport setup --step runtime`.")
        }
        // HOME and TMPDIR of the contract must exist before Wine starts.
        try paths.createLayout()
    }

    /// `wine ARGS...` to completion, output appended to `log`.
    @discardableResult
    public func run(_ arguments: [String], log: URL, timeout: TimeInterval, cwd: URL? = nil) throws -> Int32 {
        try preflight()
        return try ProcessRunner.run(paths.wine.path, arguments, environment: environment,
                                     cwd: cwd ?? paths.dataRoot, log: log, timeout: timeout)
    }

    /// `wineserver ARGS...` to completion.
    @discardableResult
    public func wineserver(_ arguments: [String], log: URL, timeout: TimeInterval) throws -> Int32 {
        try preflight()
        return try ProcessRunner.run(paths.wineserver.path, arguments, environment: environment,
                                     cwd: paths.dataRoot, log: log, timeout: timeout)
    }

    /// `wine ARGS...` detached (survives the caller). Returns the pid of the `wine` client.
    public func spawn(_ arguments: [String], cwd: URL, log: URL) throws -> pid_t {
        try preflight()
        return try ProcessRunner.spawnDetached(paths.wine.path, arguments, environment: environment, cwd: cwd, log: log)
    }

    /// `wine --version`, for the runtime smoke check. Starts no wineserver.
    public func version() throws -> String {
        try preflight()
        let out = try ProcessRunner.capture(paths.wine.path, ["--version"], environment: environment,
                                            cwd: paths.dataRoot, timeout: 60)
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
