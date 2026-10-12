import Foundation

/// The installed game's version, from `xdt_Data/StreamingAssets/version.xdtconf` (a JSON file
/// the TapTap download writes; for example `"Version": "0.5.5"`, `"MajorVersion": "5847751"`).
public struct GameVersion: Codable, Sendable, Equatable {
    /// The player-facing version ("0.5.5").
    public var version: String
    /// The build number (MajorVersion, "5847751").
    public var build: String?
    /// The release branch ("obt_release5").
    public var branch: String?
    /// The resource (hot update) version.
    public var resVersion: String?

    public init(version: String, build: String? = nil, branch: String? = nil, resVersion: String? = nil) {
        self.version = version; self.build = build; self.branch = branch; self.resVersion = resVersion
    }

    private struct File: Decodable {
        var Version: String?
        var MajorVersion: String?
        var Branch: String?
        var ResVersion: String?
    }

    /// nil when the file is absent, unreadable, or names no version.
    public static func read(_ paths: Paths) -> GameVersion? {
        read(file: paths.gameVersionFile)
    }

    public static func read(file: URL) -> GameVersion? {
        guard var data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        guard let f = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        guard let version = clean(f.Version) else { return nil }
        return GameVersion(version: version, build: clean(f.MajorVersion), branch: clean(f.Branch),
                           resVersion: clean(f.ResVersion))
    }
}
