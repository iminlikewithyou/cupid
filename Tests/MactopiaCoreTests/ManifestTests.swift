import XCTest
@testable import MactopiaCore

final class ManifestTests: XCTestCase {
    /// A synthetic runtime: the required files plus a couple of others, and its manifest.
    func makeRuntime() throws -> (URL, RuntimeManifest) {
        let root = try tempDir()
        var files: [String: RuntimeManifest.Entry] = [:]
        for (i, rel) in (RuntimeManifest.requiredFiles + ["lib/wine/x86_64-windows/ntdll.dll", "licenses/LGPL"]).enumerated() {
            let text = "file \(i) \(rel)\n"
            try write(text, to: root.appendingPathComponent(rel))
            files[rel] = .init(sha256: sha256Hex(text), bytes: Int64(text.utf8.count))
        }
        let manifest = RuntimeManifest(version: "phase2-test.1", files: files)
        try write(#"{"schema":1,"version":"phase2-test.1","minimum_macos":"15.0","files":{}}"#, to: root.appendingPathComponent("runtime.json"))
        return (root, manifest)
    }

    func testCleanRuntimeVerifies() throws {
        let (root, manifest) = try makeRuntime()
        let report = manifest.verify(root: root, expectedVersion: "phase2-test.1")
        XCTAssertEqual(report.problems, [])
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.checked, RuntimeManifest.requiredFiles.count + 2)
    }

    func testDetectsChangedResizedMissingAndUnlisted() throws {
        let (root, manifest) = try makeRuntime()
        // Same size, different content.
        let ntdll = root.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll")
        var text = try String(contentsOf: ntdll, encoding: .utf8)
        text = String(text.dropLast()) + "X"
        try write(text, to: ntdll)
        try write("longer than before, surely\n", to: root.appendingPathComponent("licenses/LGPL"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("config/dxmt.conf"))
        try write("x", to: root.appendingPathComponent("lib/wine/extra.dll"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("bin/link").path, withDestinationPath: "wine")
        let report = manifest.verify(root: root, expectedVersion: "other")
        XCTAssertFalse(report.ok)
        let p = report.problems.joined(separator: "\n")
        XCTAssertTrue(p.contains("sha256 mismatch: lib/wine/x86_64-windows/ntdll.dll"), p)
        XCTAssertTrue(p.contains("licenses/LGPL") && p.contains("size"), p)
        XCTAssertTrue(p.contains("missing: config/dxmt.conf"), p)
        XCTAssertTrue(p.contains("unlisted: lib/wine/extra.dll"), p)
        XCTAssertTrue(p.contains("unlisted: bin/link"), p)
        XCTAssertTrue(p.contains("version phase2-test.1 != expected other"), p)
    }

    func testGameModeBundleAndDSStoreAreAllowed() throws {
        let (root, manifest) = try makeRuntime()
        try write("plist", to: root.appendingPathComponent("lib/wine/game-mode/xdt.app/Contents/Info.plist"))
        try write("", to: root.appendingPathComponent("lib/.DS_Store"))
        XCTAssertEqual(manifest.verify(root: root).problems, [])
        // Another bundle in game-mode/ is not ours and must be listed.
        try write("plist", to: root.appendingPathComponent("lib/wine/game-mode/Other.app/Contents/Info.plist"))
        XCTAssertEqual(manifest.verify(root: root).problems, ["unlisted: lib/wine/game-mode/Other.app/Contents/Info.plist"])
    }

    func testSymlinkEntriesAndUnsafePaths() throws {
        let (root, base) = try makeRuntime()
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("lib/libfoo.dylib").path, withDestinationPath: "libfoo.1.dylib")
        var files = base.files
        files["lib/libfoo.dylib"] = .init(sha256: nil, bytes: nil, symlink: "libfoo.1.dylib")
        XCTAssertEqual(RuntimeManifest(version: "v", files: files).verify(root: root).problems, [])
        files["lib/libfoo.dylib"] = .init(sha256: nil, bytes: nil, symlink: "elsewhere.dylib")
        XCTAssertEqual(RuntimeManifest(version: "v", files: files).verify(root: root).problems, ["symlink mismatch: lib/libfoo.dylib"])
        files["lib/libfoo.dylib"] = .init(sha256: nil, bytes: nil, symlink: "libfoo.1.dylib")
        files["../outside"] = .init(sha256: "00", bytes: 1)
        XCTAssertTrue(RuntimeManifest(version: "v", files: files).verify(root: root).problems.contains("unsafe path in manifest: ../outside"))
    }

    func testRequiredFilesMustBeListed() throws {
        let (root, base) = try makeRuntime()
        var files = base.files
        files.removeValue(forKey: "bin/wineserver")
        let problems = RuntimeManifest(version: "v", files: files).verify(root: root).problems
        XCTAssertTrue(problems.contains("manifest lacks required file: bin/wineserver"))
        XCTAssertTrue(problems.contains("unlisted: bin/wineserver"))
    }

    func testManifestDecoding() throws {
        let root = try tempDir()
        try write(#"{"schema":1,"version":"phase2-20261007.3","minimum_macos":"15.0","files":{"bin/wine":{"sha256":"ab","bytes":3}},"status":"x"}"#,
                  to: root.appendingPathComponent("runtime.json"))
        let m = try RuntimeManifest.load(root.appendingPathComponent("runtime.json"))
        XCTAssertEqual(m.version, "phase2-20261007.3")
        XCTAssertEqual(m.minimumMacOS, "15.0")
        XCTAssertEqual(m.files["bin/wine"], .init(sha256: "ab", bytes: 3))
    }

    func testUUID5() {
        // uuid.uuid5(uuid.NAMESPACE_DNS, "python.org") == 886313e1-3b8a-5372-9b90-0c9aee199e5d
        let dns: [UInt8] = [0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        let hex = GameModeBundle.uuid5(namespace: dns, name: "python.org").map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "886313e13b8a53729b900c9aee199e5d")
    }
}
