import Foundation

/// The TapTap Global installer (docs/PHASE2.md "TapTap install and game download").
public enum TapTapInstaller {
    public static let url = URL(string: "https://d.tap.io/pc/latest/coop-pc?jid=id231364")!
    public static let fileName = "TapTap_Global_PC_Setup_0.3.0.1000_coop-pc-id231364-.exe"
    public static let bytes: Int64 = 78_685_088
    public static let sha256 = "e5d931e2e8afa486e47f5844bed1be092367d8dc1f8aab1b99526d9e0621bc38"

    public static func file(_ paths: Paths) -> URL { paths.downloads.appendingPathComponent(fileName) }

    public enum Check: Sendable, Equatable {
        case missing
        case pinned
        /// TapTap updated its installer: proceed only after the user confirms.
        case changed(bytes: Int64, sha256: String)
    }

    public static func check(_ file: URL) -> Check {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value else { return .missing }
        guard let sha = try? Hashing.sha256(of: file) else { return .missing }
        return size == bytes && sha == sha256 ? .pinned : .changed(bytes: size, sha256: sha)
    }

    /// Download (unless a pinned copy is already there) and check it.
    public static func download(_ paths: Paths, progress: Downloader.Progress? = nil) throws -> Check {
        let target = file(paths)
        if check(target) == .pinned { return .pinned }
        try paths.createLayout()
        try Downloader.download(url, to: target, progress: progress)
        return check(target)
    }

    /// The steps the user must take in the installer window (no silent mode works under Wine).
    public static let instructions = """
    The TapTap installer window ("Welcome to TapTap Setup") is opening. In it:
      1. Click the circle next to "I have read and agree to the above terms."
         (This accepts TapTap's terms; it is your decision.)
      2. Leave "Custom Options" as they are, so it installs to C:\\Program Files\\TapTapGlobal.
      3. Click "Install Now" and wait for it to finish.
    """

    /// Start the installer GUI, detached. cwd is the data root, never downloads/.
    public static func run(_ paths: Paths) throws -> Int32 {
        try SessionGuard.requireIdle(paths, to: "start the TapTap installer")
        return try Wine(paths: paths).spawn([file(paths).path], cwd: paths.dataRoot, log: Logs.installer(paths))
    }
}

/// The installed TapTap launcher (Electron).
public enum TapTapLauncher {
    public static func isInstalled(_ paths: Paths) -> Bool {
        FileManager.default.fileExists(atPath: paths.launcherExe.path)
    }

    public static let arguments = [Game.launcherWindowsExe] + Game.launcherFlags

    public static let downloadInstructions = """
    The TapTap launcher is opening. In it:
      1. Sign in to TapTap if it asks.
      2. Find Heartopia and click "Download & Install" (about 13 GB). Keep the default location
         (C:\\TapTapGlobal\\Apps\\231364).
      3. Keep the launcher open until the download finishes.
    """

    /// Start the launcher with the flags that make its window render. Refuses if the game runs;
    /// returns nil if the launcher is already open.
    public static func run(_ paths: Paths) throws -> Int32? {
        guard isInstalled(paths) else {
            throw MactopiaError(.launcherNotInstalled, "The TapTap launcher is not installed. Run `mactopia setup --step taptap`.")
        }
        let snapshot = SessionSnapshot.take(paths)
        if let game = snapshot.game {
            throw MactopiaError(.sessionAlive, "Heartopia is running (pid \(game.pid)); quit it before opening the TapTap launcher.")
        }
        if !snapshot.launcher.isEmpty { return nil }
        try SessionGuard.requireIdle(paths, to: "start the TapTap launcher")
        return try Wine(paths: paths).spawn(arguments, cwd: paths.launcherDir, log: Logs.launcher(paths))
    }
}

/// `GameFileInfo.json`: the complete file manifest TapTap writes into the game folder.
public struct GameFileInfo: Decodable, Sendable {
    public struct File: Decodable, Sendable, Equatable {
        public let fileName: String
        public let fileSize: Int64
        public let md5Hash: String
        enum CodingKeys: String, CodingKey { case fileName = "FileName", fileSize = "FileSize", md5Hash = "Md5Hash" }
        public init(fileName: String, fileSize: Int64, md5Hash: String) {
            self.fileName = fileName; self.fileSize = fileSize; self.md5Hash = md5Hash
        }
    }
    public let totalFileSize: Int64
    public let files: [File]
    enum CodingKeys: String, CodingKey { case totalFileSize = "TotalFileSize", files = "FileInfos" }

    public init(totalFileSize: Int64, files: [File]) { self.totalFileSize = totalFileSize; self.files = files }

    public static func load(_ url: URL) throws -> GameFileInfo {
        try JSONDecoder().decode(GameFileInfo.self, from: Data(contentsOf: url))
    }

    static func isSafe(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\")
            && !name.split(separator: "/").contains("..")
    }
}

/// Game download progress and the "installed" decision.
public enum GameInstall {
    public struct Progress: Sendable, Equatable, Codable {
        public let bytesOnDisk: Int64
        /// GameFileInfo.json TotalFileSize, once that file exists.
        public let totalBytes: Int64?
        /// 0...1, nil while the total is unknown.
        public var fraction: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, max(0, Double(bytesOnDisk) / Double(totalBytes)))
        }
        public var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }
        public init(bytesOnDisk: Int64, totalBytes: Int64?) { self.bytesOnDisk = bytesOnDisk; self.totalBytes = totalBytes }
    }

    /// Logical size of every regular file under `dir`, excluding GameFileInfo.json itself.
    public static func folderSize(_ dir: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            if url.lastPathComponent == "GameFileInfo.json" && url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // VERIFY: assumes TapTap writes files at their final size as they complete (no preallocation
    // of the whole folder) and writes GameFileInfo.json early in the download.
    public static func progress(_ paths: Paths) -> Progress {
        let total = (try? GameFileInfo.load(paths.gameFileInfo))?.totalFileSize
        return Progress(bytesOnDisk: folderSize(paths.gameDir), totalBytes: total)
    }

    public struct Check: Sendable, Equatable {
        public var listed = 0
        public var missing: [String] = []
        public var wrongSize: [String] = []
        /// PE files that are the listed bytes plus an appended Authenticode signature (accepted;
        /// excluded from the md5 sample).
        public var signedPE: [String] = []
        public var md5Checked = 0
        public var md5Mismatch: [String] = []
        public var ok: Bool { listed > 0 && missing.isEmpty && wrongSize.isEmpty && md5Mismatch.isEmpty }
    }

    /// Indices of files to md5: every top-level file plus an even spread of `count`, skipping
    /// files over `maxBytes` (setup's spot check; Repair passes `count: .max`).
    public static func sample(_ files: [GameFileInfo.File], count: Int, maxBytes: Int64) -> [Int] {
        guard count > 0 else { return [] }
        var picked = Set<Int>()
        for (i, f) in files.enumerated() where !f.fileName.contains("/") { picked.insert(i) }
        let eligible = files.indices.filter { files[$0].fileSize <= maxBytes }
        if count >= eligible.count { picked.formUnion(eligible) }
        else {
            let step = Double(eligible.count) / Double(count)
            for k in 0..<count { picked.insert(eligible[Int(Double(k) * step)]) }
        }
        return picked.sorted()
    }

    /// Every listed file present at its size; md5 of a sample.
    /// `progress(done, total)` is called from worker threads during the md5 phase; when
    /// `isCancelled` returns true the remaining md5 sums are skipped (`md5Checked` counts only
    /// the files actually hashed).
    public static func verify(_ paths: Paths, info: GameFileInfo, md5Sample: Int = 300,
                              maxSampleBytes: Int64 = 64 << 20,
                              progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil,
                              isCancelled: (@Sendable () -> Bool)? = nil) -> Check {
        var check = Check()
        check.listed = info.files.count
        let fm = FileManager.default
        for f in info.files {
            guard GameFileInfo.isSafe(f.fileName) else { check.missing.append(f.fileName); continue }
            let url = paths.gameDir.appendingPathComponent(f.fileName)
            guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
                check.missing.append(f.fileName); continue
            }
            if size != f.fileSize {
                if Authenticode.isListedFilePlusSignature(url, fileSize: size, listedSize: f.fileSize) {
                    check.signedPE.append(f.fileName)
                } else {
                    check.wrongSize.append(f.fileName)
                }
            }
        }
        guard check.missing.isEmpty, check.wrongSize.isEmpty else { return check }
        let signed = Set(check.signedPE)
        let indices = sample(info.files, count: md5Sample, maxBytes: maxSampleBytes).filter { !signed.contains(info.files[$0].fileName) }
        let mismatches = Locked<[String]>([])
        let hashed = Locked(0)
        let gameDir = paths.gameDir
        let total = indices.count
        DispatchQueue.concurrentPerform(iterations: indices.count) { k in
            if isCancelled?() == true { return }
            let f = info.files[indices[k]]
            let got = try? Hashing.md5(of: gameDir.appendingPathComponent(f.fileName))
            if got?.lowercased() != f.md5Hash.lowercased() { mismatches.withLock { $0.append(f.fileName) } }
            let done = hashed.withLock { $0 += 1; return $0 }
            progress?(done, total)
        }
        check.md5Checked = hashed.current
        check.md5Mismatch = mismatches.current.sorted()
        return check
    }

    public enum State: Sendable, Equatable {
        case notStarted
        case downloading(Progress)
        case incomplete(Check)
        case installed(Check)
    }

    /// Installed when xdt.exe exists and GameFileInfo.json's entries match (sizes all, md5 sampled).
    public static func state(_ paths: Paths, md5Sample: Int = 300) -> State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.gameDir.path) else { return .notStarted }
        guard let info = try? GameFileInfo.load(paths.gameFileInfo), fm.fileExists(atPath: paths.gameExe.path) else {
            return .downloading(progress(paths))
        }
        let check = verify(paths, info: info, md5Sample: md5Sample)
        if check.ok { return .installed(check) }
        if !check.missing.isEmpty || !check.wrongSize.isEmpty { return .downloading(progress(paths)) }
        return .incomplete(check)
    }
}

/// TapTap's GameFileInfo.json lists the PE files (exe/dll) as they were before Authenticode
/// signing: on disk, 31 of them are the listed size plus a signature appended at the end
/// (verified 2026-10-11 for Heartopia 0.5.5: the PE security directory starts at the listed size,
/// or up to 7 bytes later for 8-byte alignment, and runs to the end of the file).
public enum Authenticode {
    /// (offset, size) of the PE security directory (the certificate table), if any.
    public static func securityDirectory(header d: [UInt8]) -> (offset: Int64, size: Int64)? {
        func u16(_ o: Int) -> Int? { o + 2 <= d.count ? Int(d[o]) | Int(d[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int64? { o + 4 <= d.count ? Int64(d[o]) | Int64(d[o + 1]) << 8 | Int64(d[o + 2]) << 16 | Int64(d[o + 3]) << 24 : nil }
        guard d.count > 0x40, d[0] == 0x4d, d[1] == 0x5a, let peOffset = u32(0x3c).map(Int.init),
              u32(peOffset) == 0x0000_4550, let magic = u16(peOffset + 24) else { return nil }
        let optional = peOffset + 24
        let dataDirectories = optional + (magic == 0x20b ? 112 : 96)
        guard let offset = u32(dataDirectories + 32), let size = u32(dataDirectories + 36), offset > 0, size > 0 else { return nil }
        return (offset, size)
    }

    public static func isListedFilePlusSignature(_ url: URL, fileSize: Int64, listedSize: Int64) -> Bool {
        guard fileSize > listedSize, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), let dir = securityDirectory(header: [UInt8](header)) else { return false }
        return matches(dir, fileSize: fileSize, listedSize: listedSize)
    }

    public static func matches(_ dir: (offset: Int64, size: Int64), fileSize: Int64, listedSize: Int64) -> Bool {
        dir.offset >= listedSize && dir.offset - listedSize < 8 && dir.offset + dir.size == fileSize
    }
}
