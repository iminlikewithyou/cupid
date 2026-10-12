import Foundation

/// `<data>/state.json`. Adopts the spike's file (`{"runtime": ..., "prefix": "created"}`);
/// every field is optional and unknown fields are dropped on the next save.
public struct AppState: Codable, Sendable, Equatable {
    /// Installed runtime version.
    public var runtime: String?
    /// "created" once the prefix exists.
    public var prefix: String?
    /// Runtime version `wineboot -u` last ran with; a different runtime re-runs it.
    public var prefixRuntime: String?
    /// Metal HUD on for `play` (menu toggle).
    public var hud: Bool?
    /// sha256 of the TapTap installer the user accepted when it no longer matched the pin.
    public var acceptedInstallerSHA256: String?
    public var taptapInstalled: Bool?
    public var gameInstalled: Bool?
    public var lastLaunch: String?

    public init() {}

    public static func load(_ paths: Paths) -> AppState {
        guard let data = try? Data(contentsOf: paths.stateFile) else { return AppState() }
        return (try? JSONDecoder().decode(AppState.self, from: data)) ?? AppState()
    }

    public static func decode(_ data: Data) throws -> AppState { try JSONDecoder().decode(AppState.self, from: data) }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    /// Writes only when something changed. Returns true when it wrote.
    @discardableResult
    public func save(_ paths: Paths) throws -> Bool {
        if AppState.load(paths) == self, FileManager.default.fileExists(atPath: paths.stateFile.path) { return false }
        try FileManager.default.createDirectory(at: paths.dataRoot, withIntermediateDirectories: true)
        try encoded().write(to: paths.stateFile, options: .atomic)
        return true
    }

    /// Load, change, save.
    @discardableResult
    public static func update(_ paths: Paths, _ change: (inout AppState) -> Void) throws -> AppState {
        var state = load(paths)
        change(&state)
        try state.save(paths)
        return state
    }
}
