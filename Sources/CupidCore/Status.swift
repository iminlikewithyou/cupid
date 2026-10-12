import Foundation

/// Everything `cupid status` reports (and the app's state machine reads). Read-only.
public struct StatusReport: Codable, Sendable {
    public struct Runtime: Codable, Sendable {
        public var expectedVersion: String
        public var installedVersion: String?
        public var path: String
        public var gameModeBundle: Bool
        /// xdt.app's identifier (nil when absent); setup regenerates it when it is not
        /// `GameModeBundle.identifier` (pre-rename bundles).
        public var gameModeBundleIdentifier: String?
        /// Only with `verify`: full manifest result.
        public var verified: Bool?
        public var problems: [String]?
    }
    public struct Prefix: Codable, Sendable {
        public var exists: Bool
        public var windows10: Bool
        public var retinaMode: String?
        public var pendingSeeds: [String]
        public var userLinks: [String]
        /// WindowsFonts links not yet in windows/Fonts (sources present on this Mac).
        public var missingFonts: [String]
        /// WindowsFonts registry values (HKLM ...\CurrentVersion\Fonts) not yet in system.reg.
        public var unregisteredFonts: [String]
        public var dxmtConfCurrent: Bool
    }
    public struct TapTap: Codable, Sendable {
        public var installerDownloaded: Bool
        public var installerPinned: Bool?
        public var launcherInstalled: Bool
    }
    public struct GameStatus: Codable, Sendable {
        /// not-started | downloading | incomplete | installed
        public var state: String
        public var exePresent: Bool
        public var bytesOnDisk: Int64?
        public var totalBytes: Int64?
        public var percent: Int?
        public var filesListed: Int?
        public var missing: Int?
        public var wrongSize: Int?
        public var signedPE: Int?
        public var md5Checked: Int?
        public var md5Mismatch: Int?
        /// From version.xdtconf (GameVersion); nil when the file is absent.
        public var version: String?
        public var build: String?
    }
    public struct SessionStatus: Codable, Sendable {
        public var alive: Bool
        public var wineserverPIDs: [Int32]
        public var game: WineProcess?
        public var gameInModeBundle: Bool
        public var window: WindowInfo?
        public var launcherRunning: Bool
        public var installerRunning: Bool
        /// The TapTap installer is (still) at work: an installer process or another non-service
        /// Windows program is alive, or a session is alive within a minute of Cupid starting
        /// the installer (its stages are separate processes with gaps in between).
        public var installerSession: Bool
        public var programs: [String]
    }

    public var dataRoot: String
    public var rosetta: Bool
    public var runtime: Runtime
    public var prefix: Prefix
    public var taptap: TapTap
    public var game: GameStatus
    public var session: SessionStatus
    public var state: AppState

    /// `verify`: full runtime manifest check and an md5 sample of the game files (slower).
    public static func gather(_ paths: Paths, verify: Bool = false) -> StatusReport {
        let fm = FileManager.default
        let installer = RuntimeInstaller(paths: paths)
        var runtime = Runtime(expectedVersion: paths.runtimeVersion, installedVersion: installer.installedVersion(),
                              path: paths.runtime.path, gameModeBundle: fm.fileExists(atPath: paths.gameModeApp.path),
                              gameModeBundleIdentifier: GameModeBundle.installedIdentifier(runtime: paths.runtime))
        if verify, installer.isPresent {
            if let report = try? installer.verify() {
                var problems = report.problems
                if runtime.gameModeBundle {
                    do { try GameModeBundle.check(runtime: paths.runtime) } catch { problems.append("\(error)") }
                }
                runtime.verified = problems.isEmpty
                runtime.problems = problems
            } else {
                runtime.verified = false
            }
        }

        let setup = PrefixSetup(paths: paths)
        let exists = setup.exists
        let user = exists ? RegFile(contentsOf: paths.userReg) : nil
        let system = exists ? RegFile(contentsOf: paths.systemReg) : nil
        let prefix = Prefix(exists: exists,
                            windows10: exists && RegistrySeeds.isWindows10(system),
                            retinaMode: user?.string(RegistrySeeds.macDriverKey, "RetinaMode"),
                            pendingSeeds: RegistrySeeds.pending(in: user).map(\.name),
                            userLinks: exists ? setup.userLinks() : [],
                            missingFonts: exists ? WindowsFonts.pending(in: paths.windowsFonts).map(\.name) : [],
                            unregisteredFonts: exists ? WindowsFonts.unregistered(in: paths.windowsFonts, systemReg: system).map(\.registryValue) : [],
                            dxmtConfCurrent: DxmtConfig.isCurrent(at: paths.dxmtConf))

        let installerFile = TapTapInstaller.file(paths)
        let downloaded = fm.fileExists(atPath: installerFile.path)
        let taptap = TapTap(installerDownloaded: downloaded,
                            installerPinned: downloaded && verify ? TapTapInstaller.check(installerFile) == .pinned : nil,
                            launcherInstalled: TapTapLauncher.isInstalled(paths))

        var game = GameStatus(state: "not-started", exePresent: fm.fileExists(atPath: paths.gameExe.path))
        if let v = GameVersion.read(paths) { game.version = v.version; game.build = v.build }
        func fill(_ c: GameInstall.Check) {
            game.filesListed = c.listed; game.missing = c.missing.count; game.wrongSize = c.wrongSize.count; game.signedPE = c.signedPE.count
            game.md5Checked = c.md5Checked; game.md5Mismatch = c.md5Mismatch.count
        }
        switch GameInstall.state(paths, md5Sample: verify ? 300 : 0) {
        case .notStarted: break
        case .downloading(let p):
            game.state = "downloading"; game.bytesOnDisk = p.bytesOnDisk; game.totalBytes = p.totalBytes; game.percent = p.percent
        case .incomplete(let c): game.state = "incomplete"; fill(c)
        case .installed(let c): game.state = "installed"; fill(c)
        }

        let state = AppState.load(paths)
        let session = Self.session(from: SessionSnapshot.take(paths),
                                   installerStarted: state.installerStarted.flatMap { ISO8601DateFormatter().date(from: $0) })

        return StatusReport(dataRoot: paths.dataRoot.path, rosetta: Rosetta.isInstalled, runtime: runtime, prefix: prefix,
                            taptap: taptap, game: game, session: session, state: state)
    }

    /// Seconds after Cupid starts the installer during which any live session counts as it.
    public static let installerGrace: TimeInterval = 60

    public static func session(from snap: SessionSnapshot, installerStarted: Date? = nil, now: Date = Date()) -> SessionStatus {
        let g = snap.game
        let recent = installerStarted.map { now.timeIntervalSince($0) < installerGrace && now >= $0 } ?? false
        let installerSession = !snap.installer.isEmpty || !snap.otherPrograms.isEmpty || (snap.isAlive && recent)
        return SessionStatus(alive: snap.isAlive, wineserverPIDs: snap.wineservers.map(\.pid), game: g,
                             gameInModeBundle: g?.path.contains("/" + GameModeBundle.relativePath + "/") == true,
                             window: g.flatMap { WindowInfo.game(pid: $0.pid) },
                             launcherRunning: !snap.launcher.isEmpty, installerRunning: !snap.installer.isEmpty,
                             installerSession: installerSession, programs: snap.windowsPrograms.map { "\($0.pid) \($0.argv0 ?? "?")" })
    }
}
