import Foundation

/// The app's window states, derived from a `StatusReport` (docs/PHASE2.md "App"). Pure: no I/O.
public enum SetupPhase: Sendable, Equatable {
    /// Rosetta 2 is not installed.
    case rosettaMissing
    /// The runtime is absent, a different version, or its Game Mode bundle is missing or stale.
    case runtime
    /// The prefix is missing or needs a step (wineboot after a runtime change, win10, seeds, links).
    case prefix(exists: Bool)
    /// The TapTap launcher is not installed yet.
    case taptap(installerRunning: Bool)
    /// TapTap is installed; Heartopia is not (yet) completely downloaded.
    case download(Download)
    /// Heartopia is installed.
    case ready(Ready)

    public struct Download: Sendable, Equatable {
        public var launcherRunning: Bool
        public var bytesOnDisk: Int64?
        public var totalBytes: Int64?
        /// 0...1 once GameFileInfo.json gives the total.
        public var fraction: Double?
        /// Every file is present but sampled md5 sums differ.
        public var incomplete: Bool
        public init(launcherRunning: Bool = false, bytesOnDisk: Int64? = nil, totalBytes: Int64? = nil,
                    fraction: Double? = nil, incomplete: Bool = false) {
            self.launcherRunning = launcherRunning; self.bytesOnDisk = bytesOnDisk; self.totalBytes = totalBytes
            self.fraction = fraction; self.incomplete = incomplete
        }
    }

    public enum Ready: Sendable, Equatable {
        /// Nothing of ours runs: the game can start.
        case idle
        /// Heartopia runs (pid of the xdt.exe process).
        case gameRunning(pid: Int32)
        /// The TapTap launcher is open (play would refuse until it closes).
        case launcherOpen
        /// Some other Wine session of ours is alive (installer, leftover services).
        case sessionBusy
    }

    /// The game can be started right now (the app's auto-launch on open).
    public var canAutoLaunch: Bool { self == .ready(.idle) }
}

/// The facts the phase depends on, separable from `StatusReport` for tests.
public struct SetupInputs: Sendable, Equatable {
    public var rosetta = true
    public var expectedRuntime = Paths.defaultRuntimeVersion
    public var installedRuntime: String?
    public var gameModeBundle = false
    /// xdt.app carries `GameModeBundle.identifier` (false for a pre-rename bundle).
    public var gameModeBundleCurrent = true
    public var prefixExists = false
    public var windows10 = false
    public var retinaMode: String?
    public var pendingSeeds: [String] = []
    public var userLinks: [String] = []
    public var missingFonts: [String] = []
    public var unregisteredFonts: [String] = []
    /// Runtime version wineboot last ran with (`state.prefixRuntime ?? state.runtime`).
    public var prefixBootedWith: String?
    public var launcherInstalled = false
    /// StatusReport.SessionStatus.installerSession.
    public var installerSession = false
    public var launcherRunning = false
    public var sessionAlive = false
    public var gamePID: Int32?
    /// StatusReport.GameStatus.state: not-started | downloading | incomplete | installed
    public var gameState = "not-started"
    public var bytesOnDisk: Int64?
    public var totalBytes: Int64?

    public init() {}

    public init(_ r: StatusReport) {
        rosetta = r.rosetta
        expectedRuntime = r.runtime.expectedVersion
        installedRuntime = r.runtime.installedVersion
        gameModeBundle = r.runtime.gameModeBundle
        gameModeBundleCurrent = r.runtime.gameModeBundleIdentifier.map { $0 == GameModeBundle.identifier } ?? true
        prefixExists = r.prefix.exists
        windows10 = r.prefix.windows10
        retinaMode = r.prefix.retinaMode
        pendingSeeds = r.prefix.pendingSeeds
        userLinks = r.prefix.userLinks
        missingFonts = r.prefix.missingFonts
        unregisteredFonts = r.prefix.unregisteredFonts
        prefixBootedWith = r.state.prefixRuntime ?? r.state.runtime
        launcherInstalled = r.taptap.launcherInstalled
        installerSession = r.session.installerSession
        launcherRunning = r.session.launcherRunning
        sessionAlive = r.session.alive
        gamePID = r.session.game?.pid
        gameState = r.game.state
        bytesOnDisk = r.game.bytesOnDisk
        totalBytes = r.game.totalBytes
    }

    public var runtimeReady: Bool { installedRuntime == expectedRuntime && gameModeBundle }

    /// Mirrors `PrefixSetup.plan` (empty plan = up to date).
    public var prefixReady: Bool {
        prefixExists && windows10 && pendingSeeds.isEmpty && userLinks.isEmpty && missingFonts.isEmpty
            && unregisteredFonts.isEmpty
            && (prefixBootedWith == nil || prefixBootedWith == expectedRuntime)
    }

    public var phase: SetupPhase {
        guard rosetta else { return .rosettaMissing }
        guard runtimeReady else { return .runtime }
        guard prefixExists else { return .prefix(exists: false) }
        // A running game wins over maintenance: never block "Show Heartopia" on a seed or on
        // regenerating xdt.app (the game may be running from it).
        if let gamePID { return .ready(.gameRunning(pid: gamePID)) }
        guard gameModeBundleCurrent else { return .runtime }
        guard prefixReady else { return .prefix(exists: true) }
        if gameState == "installed" {
            if launcherRunning { return .ready(.launcherOpen) }
            if sessionAlive { return .ready(.sessionBusy) }
            return .ready(.idle)
        }
        // TapTapGlobal.exe is on disk before the installer finishes ("Installation complete" and
        // Launch come after it): stay on the TapTap step while the installer is at work, until
        // TapTap itself opens (then the restart with Cupid's settings takes over).
        let installerAtWork = installerSession && !launcherRunning && gameState == "not-started"
        guard launcherInstalled, !installerAtWork else { return .taptap(installerRunning: installerSession) }
        var d = SetupPhase.Download(launcherRunning: launcherRunning, bytesOnDisk: bytesOnDisk, totalBytes: totalBytes,
                                    incomplete: gameState == "incomplete")
        if let have = bytesOnDisk, let total = totalBytes, total > 0 {
            d.fraction = min(1, max(0, Double(have) / Double(total)))
        }
        return .download(d)
    }
}

extension StatusReport {
    public var phase: SetupPhase { SetupInputs(self).phase }
}

/// The five steps the app's window shows as a row of dots (Runtime, Windows, TapTap, Download,
/// Ready). Several phases map onto one step; Rosetta counts as part of the runtime step.
public enum SetupStep: Int, Sendable, CaseIterable, Comparable {
    case runtime, windows, taptap, download, ready

    public var label: String {
        switch self {
        case .runtime: "Runtime"
        case .windows: "Windows"
        case .taptap: "TapTap"
        case .download: "Download"
        case .ready: "Ready"
        }
    }

    public static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }
}

extension SetupPhase {
    /// The step dot this phase highlights.
    public var step: SetupStep {
        switch self {
        case .rosettaMissing, .runtime: .runtime
        case .prefix: .windows
        case .taptap: .taptap
        case .download: .download
        case .ready: .ready
        }
    }
}

/// Download speed from periodic samples of the bytes on disk, for an ETA. Pure: the caller
/// passes the clock. Keeps the last `window` seconds of samples; a drop in the byte count (a
/// restarted or re-verified download) starts over.
public struct DownloadRate: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public var time: Date
        public var bytes: Int64
    }

    public private(set) var samples: [Sample] = []
    public var window: TimeInterval
    /// Shortest span of samples that gives a rate (a single 2 s refresh is too noisy).
    public var minimumSpan: TimeInterval

    public init(window: TimeInterval = 60, minimumSpan: TimeInterval = 6) {
        self.window = window
        self.minimumSpan = minimumSpan
    }

    public mutating func add(bytes: Int64, at time: Date) {
        if let last = samples.last, bytes < last.bytes || time < last.time { samples.removeAll() }
        samples.append(Sample(time: time, bytes: bytes))
        samples.removeAll { time.timeIntervalSince($0.time) > window }
    }

    public mutating func reset() { samples.removeAll() }

    /// Bytes per second over the window, nil until the samples span `minimumSpan` with progress.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time.timeIntervalSince(first.time)
        let delta = last.bytes - first.bytes
        guard span >= minimumSpan, delta > 0 else { return nil }
        return Double(delta) / span
    }

    /// Seconds left for `remaining` bytes at the current rate.
    public func eta(remaining: Int64) -> TimeInterval? {
        guard let rate = bytesPerSecond else { return nil }
        return Double(max(0, remaining)) / rate
    }
}

/// Disk space for a complete setup, for the welcome screen. Sizes in GB (10^9 bytes), as the
/// Finder shows them: the runtime archive extracted, Heartopia's TapTap download
/// (GameFileInfo.json TotalFileSize is 13.9 GB), and TapTap, the Windows environment and caches.
public enum SetupSpace {
    public static let runtimeGB = 1.5
    public static let gameGB = 13.0
    public static let otherGB = 2.5

    /// Rounded to a whole GB: 17.
    public static var totalGB: Int { Int((runtimeGB + gameGB + otherGB).rounded()) }
    public static var totalBytes: Int64 { Int64(totalGB) * 1_000_000_000 }

    /// `available` (volumeAvailableCapacityForImportantUsage) is below a complete setup.
    public static func isShort(available: Int64?) -> Bool {
        guard let available else { return false }
        return available < totalBytes
    }
}

extension SetupPhase {
    /// The welcome screen comes first while nothing is installed (Rosetta missing, or no runtime
    /// at all) until it is dismissed for this data folder (`AppState.welcomed`).
    public func needsWelcome(runtimeInstalled: Bool, welcomed: Bool) -> Bool {
        guard !welcomed else { return false }
        switch self {
        case .rosettaMissing: return true
        case .runtime: return !runtimeInstalled
        default: return false
        }
    }
}
