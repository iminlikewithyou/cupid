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
}
