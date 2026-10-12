import XCTest
@testable import HeartportCore

final class SetupFlowTests: XCTestCase {
    /// Everything installed, nothing running.
    func readyInputs() -> SetupInputs {
        var i = SetupInputs()
        i.installedRuntime = i.expectedRuntime
        i.gameModeBundle = true
        i.prefixExists = true
        i.windows10 = true
        i.retinaMode = "N"
        i.prefixBootedWith = i.expectedRuntime
        i.launcherInstalled = true
        i.gameState = "installed"
        return i
    }

    func testOrderOfSetupStates() {
        var i = readyInputs()
        XCTAssertEqual(i.phase, .ready(.idle))
        XCTAssertTrue(i.phase.canAutoLaunch)

        i.rosetta = false
        XCTAssertEqual(i.phase, .rosettaMissing)
        i.rosetta = true

        i.installedRuntime = nil
        XCTAssertEqual(i.phase, .runtime)
        i.installedRuntime = "some-other-version"
        XCTAssertEqual(i.phase, .runtime)
        i.installedRuntime = i.expectedRuntime
        i.gameModeBundle = false
        XCTAssertEqual(i.phase, .runtime)
        i.gameModeBundle = true

        i.prefixExists = false
        XCTAssertEqual(i.phase, .prefix(exists: false))
        i.prefixExists = true
        i.windows10 = false
        XCTAssertEqual(i.phase, .prefix(exists: true))
        i.windows10 = true
        i.pendingSeeds = ["RetinaMode"]
        XCTAssertEqual(i.phase, .prefix(exists: true))
        i.pendingSeeds = []
        i.userLinks = ["crossover/Desktop"]
        XCTAssertEqual(i.phase, .prefix(exists: true))
        i.userLinks = []
        i.prefixBootedWith = "older"
        XCTAssertEqual(i.phase, .prefix(exists: true))
        i.prefixBootedWith = nil // spike prefix without the field: adopted
        XCTAssertEqual(i.phase, .ready(.idle))
    }

    func testFreshMachineFlow() {
        var i = SetupInputs()
        XCTAssertEqual(i.phase, .runtime)
        i = readyInputs()
        i.launcherInstalled = false
        i.gameState = "not-started"
        XCTAssertEqual(i.phase, .taptap(installerRunning: false))
        i.installerRunning = true; i.sessionAlive = true
        XCTAssertEqual(i.phase, .taptap(installerRunning: true))
        i.installerRunning = false
        i.launcherInstalled = true; i.launcherRunning = true
        XCTAssertEqual(i.phase, .download(.init(launcherRunning: true)))
        i.gameState = "downloading"; i.bytesOnDisk = 250; i.totalBytes = 1000
        XCTAssertEqual(i.phase, .download(.init(launcherRunning: true, bytesOnDisk: 250, totalBytes: 1000, fraction: 0.25)))
        i.bytesOnDisk = 2000 // capped
        guard case .download(let d) = i.phase else { return XCTFail() }
        XCTAssertEqual(d.fraction, 1)
        i.gameState = "incomplete"
        guard case .download(let d2) = i.phase else { return XCTFail() }
        XCTAssertTrue(d2.incomplete)
        i.gameState = "installed"
        XCTAssertEqual(i.phase, .ready(.launcherOpen))
        XCTAssertFalse(i.phase.canAutoLaunch)
        i.launcherRunning = false
        XCTAssertEqual(i.phase, .ready(.sessionBusy))
        i.sessionAlive = false
        XCTAssertEqual(i.phase, .ready(.idle))
    }

    func testRunningGameWinsOverMaintenance() {
        var i = readyInputs()
        i.sessionAlive = true; i.gamePID = 4242
        XCTAssertEqual(i.phase, .ready(.gameRunning(pid: 4242)))
        i.pendingSeeds = ["FXAAEnabledString_h219820651"]
        XCTAssertEqual(i.phase, .ready(.gameRunning(pid: 4242)))
        i.launcherInstalled = false; i.gameState = "downloading"
        XCTAssertEqual(i.phase, .ready(.gameRunning(pid: 4242)))
        i.installedRuntime = nil
        XCTAssertEqual(i.phase, .runtime)
    }

    func testStaleGameModeBundle() {
        var i = readyInputs()
        i.gameModeBundleCurrent = false
        XCTAssertEqual(i.phase, .runtime)
        i.sessionAlive = true; i.gamePID = 7
        XCTAssertEqual(i.phase, .ready(.gameRunning(pid: 7)))
    }

    func testGameInstalledWithoutLauncherIsReady() {
        var i = readyInputs()
        i.launcherInstalled = false
        XCTAssertEqual(i.phase, .ready(.idle))
    }

    func testEmptyDataRootMapsToRuntimeOrRosetta() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = StatusReport.gather(Paths(dataRoot: root))
        XCTAssertEqual(report.phase, report.rosetta ? .runtime : .rosettaMissing)
        // gather is read-only: nothing was created in the empty root.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testInputsFromReport() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(dataRoot: root)
        try AppState.update(paths) { $0.runtime = "r1"; $0.prefixRuntime = "r2" }
        let inputs = SetupInputs(StatusReport.gather(paths))
        XCTAssertEqual(inputs.prefixBootedWith, "r2")
        XCTAssertNil(inputs.installedRuntime)
        XCTAssertFalse(inputs.prefixExists)
        XCTAssertEqual(inputs.gameState, "not-started")
    }

    func testStepIndexMapping() {
        XCTAssertEqual(SetupStep.allCases.map(\.label), ["Runtime", "Windows", "TapTap", "Download", "Ready"])
        XCTAssertEqual(SetupPhase.rosettaMissing.step, .runtime)
        XCTAssertEqual(SetupPhase.runtime.step, .runtime)
        XCTAssertEqual(SetupPhase.prefix(exists: false).step, .windows)
        XCTAssertEqual(SetupPhase.prefix(exists: true).step, .windows)
        XCTAssertEqual(SetupPhase.taptap(installerRunning: true).step, .taptap)
        XCTAssertEqual(SetupPhase.download(.init()).step, .download)
        XCTAssertEqual(SetupPhase.ready(.idle).step, .ready)
        XCTAssertEqual(SetupPhase.ready(.gameRunning(pid: 1)).step, .ready)
        XCTAssertTrue(SetupStep.windows < .taptap)
        // The flow only moves forward through the steps.
        var i = SetupInputs()
        XCTAssertEqual(i.phase.step.rawValue, 0)
        i = readyInputs()
        XCTAssertEqual(i.phase.step, .ready)
    }

    func testDownloadRateAndETA() {
        var rate = DownloadRate(window: 60, minimumSpan: 6)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        rate.add(bytes: 1_000, at: t0)
        XCTAssertNil(rate.bytesPerSecond)
        rate.add(bytes: 3_000, at: t0.addingTimeInterval(2))
        XCTAssertNil(rate.bytesPerSecond, "span below the minimum")
        rate.add(bytes: 11_000, at: t0.addingTimeInterval(10))
        XCTAssertEqual(rate.bytesPerSecond, 1_000)
        XCTAssertEqual(rate.eta(remaining: 50_000), 50)
        XCTAssertEqual(rate.eta(remaining: -5), 0)

        // Old samples fall out of the window.
        rate.add(bytes: 111_000, at: t0.addingTimeInterval(100))
        XCTAssertEqual(rate.samples.count, 1)
        XCTAssertNil(rate.bytesPerSecond)

        // No progress gives no rate; a drop in bytes starts over.
        var stalled = DownloadRate(minimumSpan: 1)
        stalled.add(bytes: 500, at: t0)
        stalled.add(bytes: 500, at: t0.addingTimeInterval(5))
        XCTAssertNil(stalled.eta(remaining: 100))
        stalled.add(bytes: 100, at: t0.addingTimeInterval(6))
        XCTAssertEqual(stalled.samples, [.init(time: t0.addingTimeInterval(6), bytes: 100)])
    }
}
