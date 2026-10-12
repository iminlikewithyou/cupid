import XCTest
@testable import HeartportCore

final class RuntimeArchiveDescriptorTests: XCTestCase {
    func testRecallWhenNoDescriptor() throws {
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("runtime.tar.gz")
        try write("x", to: archive)
        XCTAssertNil(try RuntimeArchiveDescriptor.beside(archive))
        XCTAssertEqual(try RuntimeArchiveDescriptor.forArchive(archive), .recall)
        XCTAssertEqual(RuntimeArchiveDescriptor.recall.version, "phase2-20261007.3")
        XCTAssertEqual(RuntimeArchiveDescriptor.recall.sha256, RecallRelease.tarballSHA256)
    }

    func testDescriptorBesideArchive() throws {
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("runtime.tar.gz")
        try write("x", to: archive)
        let sha = String(repeating: "AB", count: 32)
        try write(#"{"version":"heartport-20261012.1","sha256":"\#(sha)","minimum_macos":"26.0"}"#,
                  to: dir.appendingPathComponent(RuntimeArchiveDescriptor.fileName))
        let d = try XCTUnwrap(RuntimeArchiveDescriptor.beside(archive))
        XCTAssertEqual(d, RuntimeArchiveDescriptor(version: "heartport-20261012.1", sha256: sha.lowercased(), minimumMacOS: "26.0"))
        // The bundled lookup follows HEARTPORT_RUNTIME_ARCHIVE.
        let bundled = RuntimeArchiveDescriptor.bundled(environment: ["HEARTPORT_RUNTIME_ARCHIVE": archive.path],
                                                       executable: URL(fileURLWithPath: "/nonexistent/bin/heartport"))
        XCTAssertEqual(bundled, d)
        XCTAssertEqual(RuntimeArchiveDescriptor.bundled(environment: [:], executable: URL(fileURLWithPath: "/nonexistent/bin/heartport")), .recall)
    }

    func testRejectsInvalidDescriptors() throws {
        let sha = String(repeating: "0", count: 64)
        for body in [#"{"version":"../evil","sha256":"\#(sha)"}"#, #"{"version":"a/b","sha256":"\#(sha)"}"#,
                     #"{"version":"ok-1","sha256":"xyz"}"#, #"{"version":"ok-1"}"#, "not json"] {
            let dir = try tempDir()
            let archive = dir.appendingPathComponent("runtime.tar.gz")
            try write(body, to: dir.appendingPathComponent(RuntimeArchiveDescriptor.fileName))
            XCTAssertThrowsError(try RuntimeArchiveDescriptor.beside(archive), body)
            // An invalid descriptor never silently becomes another pin when bundled.
            XCTAssertEqual(RuntimeArchiveDescriptor.bundled(environment: ["HEARTPORT_RUNTIME_ARCHIVE": archive.path],
                                                            executable: URL(fileURLWithPath: "/nonexistent/x")), .recall)
        }
    }

    func testExtractChecksDescriptorVersionAndSHA() throws {
        let dir = try tempDir()
        let archive = dir.appendingPathComponent("runtime.tar.gz")
        try write("not really a tarball", to: archive)
        let paths = Paths(dataRoot: try tempDir(), runtimeVersion: "heartport-test.1")
        let installer = RuntimeInstaller(paths: paths)
        let staging = dir.appendingPathComponent("staging")
        // No descriptor: Recall's version is expected, so this paths' version is refused.
        XCTAssertThrowsError(try installer.extractAndVerify(archive: archive, into: staging)) { error in
            XCTAssertTrue("\(error)".contains("expected heartport-test.1"), "\(error)")
        }
        // Matching version, wrong sha256.
        try write(#"{"version":"heartport-test.1","sha256":"\#(String(repeating: "0", count: 64))"}"#,
                  to: dir.appendingPathComponent(RuntimeArchiveDescriptor.fileName))
        XCTAssertThrowsError(try installer.extractAndVerify(archive: archive, into: staging)) { error in
            XCTAssertTrue("\(error)".contains("does not match"), "\(error)")
        }
    }
}
