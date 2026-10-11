import Foundation

/// The app's window states, derived from a `StatusReport` (docs/PHASE2.md "App"). Pure: no I/O.
public enum SetupPhase: Sendable, Equatable {
    /// Rosetta 2 is not installed.
    case rosettaMissing
    /// The runtime is absent, a different version, or lacks the Game Mode bundle.
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
    public var prefixExists = false
    public var windows10 = false
    public var retinaMode: String?
    public var pendingSeeds: [String] = []
    public var userLinks: [String] = []
    /// Runtime version wineboot last ran with (`state.prefixRuntime ?? state.runtime`).
    public var prefixBootedWith: String?
    public var launcherInstalled = false
    public var installerRunning = false
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
        prefixExists = r.prefix.exists
        windows10 = r.prefix.windows10
        retinaMode = r.prefix.retinaMode
        pendingSeeds = r.prefix.pendingSeeds
        userLinks = r.prefix.userLinks
        prefixBootedWith = r.state.prefixRuntime ?? r.state.runtime
        launcherInstalled = r.taptap.launcherInstalled
        installerRunning = r.session.installerRunning
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
        prefixExists && windows10 && pendingSeeds.isEmpty && userLinks.isEmpty
            && (prefixBootedWith == nil || prefixBootedWith == expectedRuntime)
    }

    public var phase: SetupPhase {
        guard rosetta else { return .rosettaMissing }
        guard runtimeReady else { return .runtime }
        guard prefixExists else { return .prefix(exists: false) }
        // A running game wins over prefix maintenance: never block "Show Heartopia" on a seed.
        if let gamePID { return .ready(.gameRunning(pid: gamePID)) }
        guard prefixReady else { return .prefix(exists: true) }
        if gameState == "installed" {
            if launcherRunning { return .ready(.launcherOpen) }
            if sessionAlive { return .ready(.sessionBusy) }
            return .ready(.idle)
        }
        guard launcherInstalled else { return .taptap(installerRunning: installerRunning) }
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
