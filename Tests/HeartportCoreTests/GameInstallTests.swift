import XCTest
@testable import HeartportCore

final class GameInstallTests: XCTestCase {
    func testProgressMath() {
        XCTAssertNil(GameInstall.Progress(bytesOnDisk: 5, totalBytes: nil).fraction)
        XCTAssertNil(GameInstall.Progress(bytesOnDisk: 5, totalBytes: 0).fraction)
        let p = GameInstall.Progress(bytesOnDisk: 6_967_827_967, totalBytes: 13_935_655_934)
        XCTAssertEqual(p.fraction!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.percent, 50)
        XCTAssertEqual(GameInstall.Progress(bytesOnDisk: 6_967_827_966, totalBytes: 13_935_655_934).percent, 49) // rounds down
        XCTAssertEqual(GameInstall.Progress(bytesOnDisk: 13_935_655_934, totalBytes: 13_935_655_934).percent, 100)
        // Signed PE files make the folder slightly larger than TotalFileSize: clamp.
        XCTAssertEqual(GameInstall.Progress(bytesOnDisk: 13_936_034_643, totalBytes: 13_935_655_934).fraction, 1)
        XCTAssertEqual(GameInstall.Progress(bytesOnDisk: 0, totalBytes: 10).percent, 0)
    }

    func makeGame(_ files: [String: String]) throws -> (Paths, GameFileInfo) {
        let paths = Paths(dataRoot: try tempDir())
        var infos: [GameFileInfo.File] = []
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            try write(text, to: paths.gameDir.appendingPathComponent(name))
            infos.append(.init(fileName: name, fileSize: Int64(text.utf8.count), md5Hash: md5Hex(text)))
        }
        let total = infos.reduce(0) { $0 + $1.fileSize }
        let json = """
        {"TotalFileSize": \(total), "FileInfos": [\(infos.map { #"{"FileName":"\#($0.fileName)","FileSize":\#($0.fileSize),"Md5Hash":"\#($0.md5Hash)"}"# }.joined(separator: ","))]}
        """
        try write(json, to: paths.gameFileInfo)
        return (paths, try GameFileInfo.load(paths.gameFileInfo))
    }

    func testDecodeAndFolderSize() throws {
        let (paths, info) = try makeGame(["xdt.exe": "MZ exe", "xdt_Data/level0": "level data", "xdt_Data/a/b.bundle": "bb"])
        XCTAssertEqual(info.files.count, 3)
        XCTAssertEqual(info.totalFileSize, 6 + 10 + 2)
        XCTAssertEqual(GameInstall.folderSize(paths.gameDir), 18) // GameFileInfo.json itself excluded
        let p = GameInstall.progress(paths)
        XCTAssertEqual(p.totalBytes, 18)
        XCTAssertEqual(p.percent, 100)
    }

    func testInstalledStates() throws {
        let (paths, _) = try makeGame(["xdt.exe": "MZ exe", "xdt_Data/level0": "level data", "UnityPlayer.dll": "dll"])
        guard case .installed(let check) = GameInstall.state(paths) else { return XCTFail("expected installed") }
        XCTAssertEqual(check.listed, 3)
        XCTAssertEqual(check.md5Checked, 3)

        try write("level dat?", to: paths.gameDir.appendingPathComponent("xdt_Data/level0"))
        guard case .incomplete(let bad) = GameInstall.state(paths) else { return XCTFail("expected incomplete") }
        XCTAssertEqual(bad.md5Mismatch, ["xdt_Data/level0"])
        // Without the md5 sample, sizes alone pass.
        if case .installed = GameInstall.state(paths, md5Sample: 0) {} else { XCTFail("sizes only") }

        try write("level", to: paths.gameDir.appendingPathComponent("xdt_Data/level0"))
        guard case .downloading(let p) = GameInstall.state(paths) else { return XCTFail("expected downloading") }
        XCTAssertEqual(p.bytesOnDisk, 6 + 5 + 3)

        try FileManager.default.removeItem(at: paths.gameExe)
        if case .downloading = GameInstall.state(paths) {} else { XCTFail("no exe: still downloading") }
        try FileManager.default.removeItem(at: paths.driveC)
        XCTAssertEqual(GameInstall.state(paths), .notStarted)
    }

    func testAuthenticodeSignedPEIsAccepted() throws {
        // A minimal PE32+ header whose security directory starts at the listed size.
        let listed = 1024, signature = 64
        var bytes = [UInt8](repeating: 0, count: listed + signature)
        bytes[0] = 0x4d; bytes[1] = 0x5a
        let pe = 0x80
        bytes[0x3c] = UInt8(pe)
        bytes[pe] = 0x50; bytes[pe + 1] = 0x45
        bytes[pe + 24] = 0x0b; bytes[pe + 25] = 0x02 // PE32+
        let dir = pe + 24 + 112 + 32
        func put(_ v: Int, _ o: Int) { for i in 0..<4 { bytes[o + i] = UInt8((v >> (8 * i)) & 0xff) } }
        put(listed, dir); put(signature, dir + 4)
        let paths = Paths(dataRoot: try tempDir())
        let exe = paths.gameExe
        try FileManager.default.createDirectory(at: paths.gameDir, withIntermediateDirectories: true)
        try Data(bytes).write(to: exe)
        XCTAssertTrue(Authenticode.isListedFilePlusSignature(exe, fileSize: Int64(bytes.count), listedSize: Int64(listed)))
        XCTAssertFalse(Authenticode.isListedFilePlusSignature(exe, fileSize: Int64(bytes.count), listedSize: Int64(listed - 100)))
        XCTAssertTrue(Authenticode.matches((1030, 66), fileSize: 1096, listedSize: 1024)) // 8-byte alignment padding
        XCTAssertFalse(Authenticode.matches((1024, 60), fileSize: 1088, listedSize: 1024))

        try write(#"{"TotalFileSize":1024,"FileInfos":[{"FileName":"xdt.exe","FileSize":1024,"Md5Hash":"00"}]}"#, to: paths.gameFileInfo)
        guard case .installed(let check) = GameInstall.state(paths) else { return XCTFail("signed exe should count as installed") }
        XCTAssertEqual(check.signedPE, ["xdt.exe"])
        XCTAssertEqual(check.md5Checked, 0)
    }

    func testSampleSpreadsAndSkipsLargeFiles() {
        var files = (0..<1000).map { GameFileInfo.File(fileName: "d/f\($0)", fileSize: 10, md5Hash: "") }
        files[0] = .init(fileName: "xdt.exe", fileSize: 10, md5Hash: "")
        files[500] = .init(fileName: "d/huge", fileSize: 1 << 40, md5Hash: "")
        let picked = GameInstall.sample(files, count: 100, maxBytes: 1 << 20)
        XCTAssertTrue(picked.contains(0))
        XCTAssertFalse(picked.contains(500))
        XCTAssertGreaterThanOrEqual(picked.count, 100)
        XCTAssertLessThanOrEqual(picked.count, 101)
        XCTAssertEqual(GameInstall.sample(files, count: 0, maxBytes: 1 << 20), [])
        XCTAssertEqual(GameInstall.sample(Array(files.prefix(5)), count: 100, maxBytes: 1 << 20), [0, 1, 2, 3, 4])
    }

    func testUnsafeNamesAreNotFollowed() {
        XCTAssertFalse(GameFileInfo.isSafe("../../etc/passwd"))
        XCTAssertFalse(GameFileInfo.isSafe("/etc/passwd"))
        XCTAssertFalse(GameFileInfo.isSafe(#"a\b"#))
        XCTAssertTrue(GameFileInfo.isSafe("xdt_Data/level0"))
    }
}
