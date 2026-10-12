import Foundation

/// Where the runtime comes from: Recall 1.3.0's DMG.
public enum RecallRelease {
    public static let dmgURL = URL(string: "https://github.com/AsherJN/recall/releases/download/v1.3.0/Recall-1.3.0.dmg")!
    public static let dmgSHA256 = "dbe066d52fc41825b4d0afc146a0d81561c6e729319f8939a2de2a733bef2b16"
    public static let tarballInDMG = "Recall.app/Contents/Resources/runtime.tar.gz"
    public static let tarballSHA256 = "66ce2eabdbe14572d4bcb485321570bdd1128647aa64f6111642f9f073f92c34"
    /// runtime.json "version" of that tarball.
    public static let runtimeVersion = "phase2-20261007.3"
    public static let minimumMacOS = "15.0"
}

/// What a runtime archive must be: its version, sha256 and minimum macOS. Recall 1.3.0's tarball
/// unless a `runtime-archive.json` sits next to the archive (Heartport's own runtime builds,
/// scripts/runtime/assemble_portable_runtime.py writes one). The descriptor is trusted as much as
/// the archive beside it: both come from the same place.
public struct RuntimeArchiveDescriptor: Codable, Sendable, Equatable {
    public let version: String
    public let sha256: String
    public let minimumMacOS: String?

    enum CodingKeys: String, CodingKey {
        case version, sha256
        case minimumMacOS = "minimum_macos"
    }

    public init(version: String, sha256: String, minimumMacOS: String? = nil) {
        self.version = version; self.sha256 = sha256; self.minimumMacOS = minimumMacOS
    }

    public static let fileName = "runtime-archive.json"
    public static let recall = RuntimeArchiveDescriptor(version: RecallRelease.runtimeVersion,
                                                        sha256: RecallRelease.tarballSHA256,
                                                        minimumMacOS: RecallRelease.minimumMacOS)

    /// The version names a directory under `runtime/`, so it must be a plain name.
    static func isValidVersion(_ v: String) -> Bool {
        v.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil && v != "." && v != ".."
    }

    static func isValidSHA256(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    /// `runtime-archive.json` next to `archive`, or nil when there is none. Throws when it exists
    /// but is unreadable or names an invalid version or sha256.
    public static func beside(_ archive: URL) throws -> RuntimeArchiveDescriptor? {
        let url = archive.deletingLastPathComponent().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let d: RuntimeArchiveDescriptor
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 64 << 10 else { throw HeartportError(.runtimeInvalid, "\(url.path) is implausibly large") }
            d = try JSONDecoder().decode(RuntimeArchiveDescriptor.self, from: data)
        } catch let error as HeartportError { throw error }
        catch { throw HeartportError(.runtimeInvalid, "\(url.path) is not valid: \(error)") }
        guard isValidVersion(d.version) else { throw HeartportError(.runtimeInvalid, "\(url.path): invalid version \"\(d.version)\"") }
        let sha = d.sha256.lowercased()
        guard isValidSHA256(sha) else { throw HeartportError(.runtimeInvalid, "\(url.path): invalid sha256 \"\(d.sha256)\"") }
        return RuntimeArchiveDescriptor(version: d.version, sha256: sha, minimumMacOS: d.minimumMacOS)
    }

    /// The descriptor for `archive`: its own `runtime-archive.json`, else Recall's.
    public static func forArchive(_ archive: URL) throws -> RuntimeArchiveDescriptor {
        try beside(archive) ?? .recall
    }

    /// The descriptor of the first bundled archive that exists (`HEARTPORT_RUNTIME_ARCHIVE`, the
    /// app's Resources, a checkout's Resources/runtime), else Recall's. An invalid descriptor
    /// counts as Recall's here; installing that archive then reports the problem.
    public static func bundled(environment: [String: String] = ProcessInfo.processInfo.environment,
                               executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")) -> RuntimeArchiveDescriptor {
        let found = RuntimeInstaller.bundledArchiveCandidates(environment: environment, executable: executable)
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let found else { return .recall }
        return ((try? beside(found)) ?? nil) ?? .recall
    }

    /// `bundled()` of this process, computed once.
    public static let current = bundled()
}

/// Installs and verifies `<data>/runtime/<version>`. Never modifies or re-signs anything in it
/// except adding `lib/wine/game-mode/xdt.app`.
public struct RuntimeInstaller: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var isPresent: Bool { FileManager.default.fileExists(atPath: paths.runtimeManifest.path) }

    /// Quick identity check (no hashing): runtime.json names our version.
    public func installedVersion() -> String? {
        (try? RuntimeManifest.load(paths.runtimeManifest))?.version
    }

    /// Full verification: every manifest entry, the loader signatures and the Game Mode bundle.
    public func verify() throws -> RuntimeManifest.Report {
        let manifest = try RuntimeManifest.load(paths.runtimeManifest)
        let report = manifest.verify(root: paths.runtime, expectedVersion: paths.runtimeVersion)
        return report
    }

    public func verifyLoaderSignatures() throws {
        let targets = [paths.wine, paths.wineserver, paths.wineLoader64].map(\.path)
        let out = try ProcessRunner.capture("/usr/bin/codesign", ["--verify", "--strict"] + targets)
        guard out.status == 0 else {
            throw HeartportError(.runtimeInvalid, "codesign --verify --strict failed for the Wine loaders: \(out.stderr)")
        }
    }

    /// Keep an existing, valid xdt.app; create it if absent, or regenerate it when it carries
    /// another identifier (one made by an earlier build). Regenerating removes and
    /// rewrites only `lib/wine/game-mode/xdt.app`, and refuses while a session is alive (the game
    /// may be running from it). Returns true when it created one.
    @discardableResult
    public func ensureGameModeBundle(minimumMacOS: String? = nil) throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.gameModeApp.path) {
            if let reason = GameModeBundle.staleReason(runtime: paths.runtime, gameExe: paths.gameExe) {
                try SessionGuard.requireIdle(paths, to: "regenerate xdt.app (\(reason))")
                try fm.removeItem(at: paths.gameModeApp)
                Logs.append(paths, "runtime: regenerating xdt.app: \(reason)")
            } else {
                try GameModeBundle.check(runtime: paths.runtime)
                return false
            }
        }
        let minimum = minimumMacOS ?? (try? RuntimeManifest.load(paths.runtimeManifest))?.minimumMacOS ?? "15.0"
        try GameModeBundle.create(runtime: paths.runtime, minimumMacOS: minimum, gameExe: paths.gameExe)
        return true
    }

    /// Candidate locations of a bundled `runtime.tar.gz`, in order.
    public static func archiveCandidates(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment,
                                         executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")) -> [URL] {
        bundledArchiveCandidates(environment: environment, executable: executable)
            + [paths.downloads.appendingPathComponent("runtime.tar.gz")]
    }

    /// The candidates that do not depend on the data root (all but the DMG download).
    public static func bundledArchiveCandidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                                                executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")) -> [URL] {
        var out: [URL] = []
        if let env = environment["HEARTPORT_RUNTIME_ARCHIVE"], !env.isEmpty { out.append(URL(fileURLWithPath: env)) }
        // In the app: Contents/Helpers/heartport -> Contents/Resources/runtime.tar.gz (PLAN.md layout).
        let exeDir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        out.append(exeDir.appendingPathComponent("../Resources/runtime.tar.gz").standardizedFileURL)
        out.append(exeDir.appendingPathComponent("../Resources/runtime/runtime.tar.gz").standardizedFileURL)
        // In a checkout: <repo>/Resources/runtime/runtime.tar.gz, found by walking up to Package.swift.
        var dir = exeDir
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                out.append(dir.appendingPathComponent("Resources/runtime/runtime.tar.gz"))
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        return out
    }

    public static func locateArchive(paths: Paths) -> URL? {
        archiveCandidates(paths: paths).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Download Recall's DMG to downloads/, check its sha256, copy runtime.tar.gz out of the
    /// read-only mounted image and check that too. Returns the tarball.
    public func fetchArchiveFromDMG(progress: Downloader.Progress? = nil, log: (String) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        try paths.createLayout()
        let dmg = paths.downloads.appendingPathComponent("Recall-1.3.0.dmg")
        let tarball = paths.downloads.appendingPathComponent("runtime.tar.gz")
        if fm.fileExists(atPath: tarball.path), (try? Hashing.sha256(of: tarball)) == RecallRelease.tarballSHA256 { return tarball }
        if !(fm.fileExists(atPath: dmg.path) && (try? Hashing.sha256(of: dmg)) == RecallRelease.dmgSHA256) {
            log("Downloading \(RecallRelease.dmgURL.absoluteString)")
            try Downloader.download(RecallRelease.dmgURL, to: dmg, progress: progress)
        }
        let got = try Hashing.sha256(of: dmg)
        guard got == RecallRelease.dmgSHA256 else {
            try? fm.removeItem(at: dmg)
            throw HeartportError(.download, "Recall DMG sha256 \(got) does not match \(RecallRelease.dmgSHA256)")
        }
        let mount = fm.temporaryDirectory.appendingPathComponent("heartport-dmg-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { _ = try? ProcessRunner.capture("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]); try? fm.removeItem(at: mount) }
        let attach = try ProcessRunner.capture("/usr/bin/hdiutil",
            ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, dmg.path], timeout: 300)
        guard attach.status == 0 else { throw HeartportError(.process, "hdiutil attach failed: \(attach.stderr)") }
        let part = tarball.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        let copy = try ProcessRunner.capture("/usr/bin/ditto", [mount.appendingPathComponent(RecallRelease.tarballInDMG).path, part.path], timeout: 300)
        guard copy.status == 0 else { throw HeartportError(.process, "Copying runtime.tar.gz out of the DMG failed: \(copy.stderr)") }
        let sha = try Hashing.sha256(of: part)
        guard sha == RecallRelease.tarballSHA256 else {
            try? fm.removeItem(at: part)
            throw HeartportError(.runtimeInvalid, "runtime.tar.gz sha256 \(sha) does not match \(RecallRelease.tarballSHA256)")
        }
        try? fm.removeItem(at: tarball)
        try fm.moveItem(at: part, to: tarball)
        try? fm.removeItem(at: dmg)
        return tarball
    }

    /// Extract `archive` (sha256-pinned by its `RuntimeArchiveDescriptor`) into a staging
    /// directory, verify it against its runtime.json, and return the staging directory. The
    /// caller moves or discards it.
    public func extractAndVerify(archive: URL, into staging: URL, log: (String) -> Void = { _ in }) throws -> RuntimeManifest.Report {
        let fm = FileManager.default
        let pin = try RuntimeArchiveDescriptor.forArchive(archive)
        guard pin.version == paths.runtimeVersion else {
            throw HeartportError(.runtimeInvalid, "\(archive.path) is runtime \(pin.version), expected \(paths.runtimeVersion)")
        }
        log("Checking \(archive.lastPathComponent) sha256")
        let sha = try Hashing.sha256(of: archive)
        guard sha == pin.sha256 else {
            throw HeartportError(.runtimeInvalid, "\(archive.path): sha256 \(sha) does not match \(pin.sha256)")
        }
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        log("Extracting")
        // bsdtar refuses absolute paths and `..` components without -P; the manifest check
        // below rejects anything unlisted, symlinks included.
        let tar = try ProcessRunner.capture("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path, "--no-same-owner"], timeout: 900)
        guard tar.status == 0 else { throw HeartportError(.process, "tar failed: \(tar.stderr)") }
        log("Verifying every file against runtime.json")
        let manifest = try RuntimeManifest.load(staging.appendingPathComponent("runtime.json"))
        return manifest.verify(root: staging, expectedVersion: paths.runtimeVersion)
    }

    /// Install from `archive`: extract to `runtime/.staging-<pid>`, verify, move into place.
    /// With `replace`, an existing runtime of the same version goes to the Trash first.
    public func install(archive: URL, replace: Bool = false, log: (String) -> Void = { _ in }) throws {
        let fm = FileManager.default
        try paths.createLayout()
        let staging = paths.runtimesDir.appendingPathComponent(".staging-\(getpid())")
        defer { try? fm.removeItem(at: staging) }
        let report = try extractAndVerify(archive: archive, into: staging, log: log)
        guard report.ok else {
            throw HeartportError(.runtimeInvalid, "The runtime archive failed verification:\n  " + report.problems.prefix(20).joined(separator: "\n  "))
        }
        if fm.fileExists(atPath: paths.runtime.path) {
            guard replace else { throw HeartportError(.io, "\(paths.runtime.path) already exists") }
            log("Moving the old runtime to the Trash")
            try fm.trashItem(at: paths.runtime, resultingItemURL: nil)
        }
        try fm.moveItem(at: staging, to: paths.runtime)
        log("Installed runtime \(report.version): \(report.checked) files verified")
    }
}
