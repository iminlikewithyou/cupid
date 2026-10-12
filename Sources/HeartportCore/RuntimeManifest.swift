import Darwin
import Foundation

/// `runtime.json` of a Recall runtime: every file with its sha256 and size.
public struct RuntimeManifest: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Equatable {
        public let sha256: String?
        public let bytes: Int64?
        public let symlink: String?
        public init(sha256: String?, bytes: Int64?, symlink: String? = nil) {
            self.sha256 = sha256; self.bytes = bytes; self.symlink = symlink
        }
    }
    public let schema: Int?
    public let version: String
    public let minimumMacOS: String?
    public let files: [String: Entry]

    enum CodingKeys: String, CodingKey {
        case schema, version, files
        case minimumMacOS = "minimum_macos"
    }

    public init(version: String, files: [String: Entry], schema: Int? = 1, minimumMacOS: String? = nil) {
        self.version = version; self.files = files; self.schema = schema; self.minimumMacOS = minimumMacOS
    }

    public static func load(_ url: URL) throws -> RuntimeManifest {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? NSNumber, size.int64Value > 8 << 20 {
            throw HeartportError(.runtimeInvalid, "runtime.json is implausibly large")
        }
        do { return try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url)) }
        catch { throw HeartportError(.runtimeInvalid, "runtime.json is not valid: \(error)") }
    }

    /// Paths not in the manifest that may exist in an installed runtime: the manifest itself,
    /// Finder's .DS_Store, and Heartport's generated Game Mode bundle.
    public static let allowedExtraPrefixes = [GameModeBundle.relativePath + "/"]

    /// Files every usable runtime must list (as Recall's portable_setup checks).
    public static let requiredFiles = [
        "bin/wine", "bin/wineserver", "config/dxmt.conf", "lib/external/libd3dshared.dylib",
        "lib/wine/x86_64-unix/winemetal.so", "lib/wine/x86_64-unix/winemac.so", "lib/wine/x86_64-unix/wine",
    ]

    static func isSafe(_ relative: String) -> Bool {
        !relative.isEmpty && !relative.hasPrefix("/") && !relative.contains("\\")
            && !relative.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    public struct Report: Sendable {
        public let version: String
        public let checked: Int
        public let problems: [String]
        public var ok: Bool { problems.isEmpty }
    }

    /// Verify `root` against this manifest: every listed file present with its size and sha256
    /// (or symlink target), and no unlisted file. Hashes in parallel.
    public func verify(root: URL, expectedVersion: String? = nil) -> Report {
        var problems: [String] = []
        if let expectedVersion, version != expectedVersion {
            problems.append("version \(version) != expected \(expectedVersion)")
        }
        for required in Self.requiredFiles where files[required] == nil {
            problems.append("manifest lacks required file: \(required)")
        }
        let names = files.keys.sorted()
        let found = Locked<[String]>([])
        @Sendable func add(_ p: String) { found.withLock { $0.append(p) } }
        let files = self.files
        DispatchQueue.concurrentPerform(iterations: names.count) { i in
            let name = names[i]
            guard Self.isSafe(name) else { add("unsafe path in manifest: \(name)"); return }
            let entry = files[name]!
            let path = root.appendingPathComponent(name).path
            var st = stat()
            guard lstat(path, &st) == 0 else { add("missing: \(name)"); return }
            if let target = entry.symlink {
                let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
                if (st.st_mode & S_IFMT) != S_IFLNK || actual != target { add("symlink mismatch: \(name)") }
                return
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else { add("not a regular file: \(name)"); return }
            if let bytes = entry.bytes, Int64(st.st_size) != bytes { add("size \(st.st_size) != \(bytes): \(name)"); return }
            guard let want = entry.sha256 else { add("no sha256 in manifest: \(name)"); return }
            guard let got = try? Hashing.sha256(of: URL(fileURLWithPath: path)) else { add("unreadable: \(name)"); return }
            if got != want.lowercased() { add("sha256 mismatch: \(name)") }
        }
        problems += found.current
        // Unlisted entries (anything but a directory; a symlink to a directory counts as a file).
        let rootPath = root.standardizedFileURL.path
        if let walker = FileManager.default.enumerator(atPath: rootPath) {
            while let rel = walker.nextObject() as? String {
                var st = stat()
                guard lstat(rootPath + "/" + rel, &st) == 0 else { continue }
                if (st.st_mode & S_IFMT) == S_IFDIR { continue }
                if rel == "runtime.json" || files[rel] != nil { continue }
                if (rel as NSString).lastPathComponent == ".DS_Store" && (st.st_mode & S_IFMT) == S_IFREG { continue }
                if Self.allowedExtraPrefixes.contains(where: { rel.hasPrefix($0) }) { continue }
                problems.append("unlisted: \(rel)")
            }
        }
        problems.sort()
        return Report(version: version, checked: files.count, problems: problems)
    }
}
