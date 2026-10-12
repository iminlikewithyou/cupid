import CryptoKit
import Foundation

/// `lib/wine/game-mode/xdt.app`: the runtime's own loader as the main executable of a bundle
/// that declares itself a game, so macOS turns Game Mode on for Heartopia. Recall's ntdll
/// starts programs named in WINE_GAME_MODE from `lib/wine/game-mode/<ExeBaseName>.app`.
///
/// Re-implemented in Swift from Recall's scripts/game_mode_app.py (Apache-2.0,
/// https://github.com/AsherJN/recall) as adapted in scripts/spike/game_mode_app.py: the copy
/// differs from the loader only in its LC_UUID (uuid5 of the loader's UUID and the bundle
/// identifier), and is signed as a bundle with the loader's entitlements and the hardened runtime.
public enum GameModeBundle {
    public static let relativePath = "lib/wine/game-mode/xdt.app"
    public static let loaderPath = "lib/wine/x86_64-unix/wine"
    public static let identifier = "app.heartport.heartopia"
    public static let addedFiles = [
        relativePath + "/Contents/Info.plist",
        relativePath + "/Contents/MacOS/wine",
        relativePath + "/Contents/_CodeSignature/CodeResources",
    ]

    /// Keys added to the loader's embedded Info.plist.
    public static func gameKeys(identifier: String = identifier) -> [String: Any] {
        [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Heartopia",
            "CFBundleExecutable": "wine",
            "LSApplicationCategoryType": "public.app-category.simulation-games",
            "LSSupportsGameMode": true,
            "GCSupportsGameMode": true, // the key's name on macOS 14 and 15
            "NSLocalNetworkUsageDescription": "Heartopia receives your sign-in from your web browser on this Mac.",
            // Kept: without a usage string, TCC kills a process that opens an input device.
            "NSMicrophoneUsageDescription": "Heartopia uses the microphone only if you turn on voice chat in the game.",
        ]
    }

    // MARK: Mach-O

    static let lcSegment64: UInt32 = 0x19, lcUUID: UInt32 = 0x1b

    static func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
    static func u64(_ d: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }
    static func name16(_ d: [UInt8], _ o: Int) -> String {
        String(decoding: d[o..<o + 16].prefix { $0 != 0 }, as: UTF8.self)
    }

    /// (cmd, offset) of each load command of a thin 64-bit little-endian Mach-O.
    static func loadCommands(_ d: [UInt8]) throws -> [(UInt32, Int)] {
        guard d.count > 32, d[0] == 0xcf, d[1] == 0xfa, d[2] == 0xed, d[3] == 0xfe else {
            throw HeartportError(.runtimeInvalid, "The Wine loader is not a 64-bit little-endian Mach-O file")
        }
        var result: [(UInt32, Int)] = []
        var offset = 32
        for _ in 0..<u32(d, 16) {
            guard offset + 8 <= d.count else { throw HeartportError(.runtimeInvalid, "Truncated Mach-O load commands") }
            result.append((u32(d, offset), offset))
            offset += Int(u32(d, offset + 4))
        }
        return result
    }

    static func embeddedInfo(_ d: [UInt8]) throws -> [String: Any] {
        for (cmd, offset) in try loadCommands(d) where cmd == lcSegment64 && name16(d, offset + 8) == "__TEXT" {
            for i in 0..<Int(u32(d, offset + 64)) {
                let section = offset + 72 + 80 * i
                guard name16(d, section) == "__info_plist" else { continue }
                let size = Int(u64(d, section + 40)), start = Int(u32(d, section + 48))
                var bytes = Array(d[start..<start + size])
                while bytes.last == 0 { bytes.removeLast() }
                guard let plist = try PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any] else { break }
                return plist
            }
        }
        throw HeartportError(.runtimeInvalid, "The Wine loader has no embedded Info.plist")
    }

    static func uuidOffset(_ d: [UInt8]) throws -> Int {
        for (cmd, offset) in try loadCommands(d) where cmd == lcUUID { return offset + 8 }
        throw HeartportError(.runtimeInvalid, "The Wine loader has no LC_UUID")
    }

    /// RFC 4122 version 5 UUID (SHA-1) of `name` in `namespace`.
    public static func uuid5(namespace: [UInt8], name: String) -> [UInt8] {
        var hasher = Insecure.SHA1()
        hasher.update(data: namespace)
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes
    }

    // MARK: create / check

    /// Create the bundle inside `runtime`. Fails if it exists.
    public static func create(runtime: URL, minimumMacOS: String = "15.0", identity: String = "-",
                              identifier: String = identifier) throws {
        let fm = FileManager.default
        let loader = runtime.appendingPathComponent(loaderPath)
        let bundle = runtime.appendingPathComponent(relativePath)
        guard !fm.fileExists(atPath: bundle.path) else {
            throw HeartportError(.io, "\(relativePath) already exists")
        }
        let data = [UInt8](try Data(contentsOf: loader))
        var info = try embeddedInfo(data)
        for (k, v) in gameKeys(identifier: identifier) { info[k] = v }
        info["LSMinimumSystemVersion"] = minimumMacOS
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        do {
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            var copy = data
            let at = try uuidOffset(data)
            copy.replaceSubrange(at..<at + 16, with: uuid5(namespace: Array(data[at..<at + 16]), name: identifier))
            let exe = macOS.appendingPathComponent("wine")
            try Data(copy).write(to: exe)
            let mode = (try fm.attributesOfItem(atPath: loader.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
            try fm.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: exe.path)

            var args = ["--force", "--options", "runtime", "--sign", identity]
            if identity != "-" { args.append("--timestamp") }
            let tmp = fm.temporaryDirectory.appendingPathComponent("heartport-ent-\(UUID().uuidString).plist")
            defer { try? fm.removeItem(at: tmp) }
            // Re-serialized as a formatted XML plist, as game_mode_app.py does (plistlib.dumps), so
            // the signature's entitlements blob, and with it the whole bundle, is byte-identical.
            if let entitlements = try entitlements(loader) {
                try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: tmp)
                args += ["--entitlements", tmp.path]
            }
            let sign = try ProcessRunner.capture("/usr/bin/codesign", args + [bundle.path])
            guard sign.status == 0 else { throw HeartportError(.process, "codesign failed: \(sign.stderr)") }
            try check(runtime: runtime, identifier: identifier)
            let added = try listFiles(bundle, relativeTo: runtime)
            guard added == addedFiles.sorted() else {
                throw HeartportError(.runtimeInvalid, "Unexpected game app files: \(added.joined(separator: ", "))")
            }
        } catch {
            try? fm.removeItem(at: bundle)
            throw error
        }
    }

    static func entitlementsXML(_ binary: URL) throws -> Data? {
        let out = try ProcessRunner.capture("/usr/bin/codesign", ["-d", "--xml", "--entitlements", "-", binary.path])
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(out.stdout.utf8)
    }

    static func entitlements(_ binary: URL) throws -> NSDictionary? {
        guard let xml = try entitlementsXML(binary) else { return nil }
        return try PropertyListSerialization.propertyList(from: xml, format: nil) as? NSDictionary
    }

    static func listFiles(_ dir: URL, relativeTo root: URL) throws -> [String] {
        let rootPath = root.standardizedFileURL.path + "/"
        var out: [String] = []
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                out.append(String(url.standardizedFileURL.path.dropFirst(rootPath.count)))
            }
        }
        return out.sorted()
    }

    /// CFBundleIdentifier of an existing xdt.app (nil when absent or unreadable).
    public static func installedIdentifier(runtime: URL) -> String? {
        let url = runtime.appendingPathComponent(relativePath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// The bundle is sealed (`codesign --verify --strict --deep`), carries our identifier and the
    /// hardened runtime, its signature covers the Info.plist, it is entitled like the loader, and
    /// it declares itself a game.
    public static func check(runtime: URL, identifier: String = identifier) throws {
        let bundle = runtime.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw HeartportError(.runtimeInvalid, "\(relativePath) is missing")
        }
        let verify = try ProcessRunner.capture("/usr/bin/codesign", ["--verify", "--strict", "--deep", bundle.path])
        guard verify.status == 0 else {
            throw HeartportError(.runtimeInvalid, "codesign --verify --strict --deep failed for xdt.app: \(verify.stderr)")
        }
        let info = try ProcessRunner.capture("/usr/bin/codesign", ["-dvv", bundle.path]).stderr
        let lines = info.split(separator: "\n").map(String.init)
        guard lines.contains("Identifier=\(identifier)"),
              lines.contains(where: { $0.hasPrefix("CodeDirectory ") && $0.range(of: #"flags=0x[0-9a-f]+\([^)]*\bruntime\b"#, options: .regularExpression) != nil }),
              lines.contains(where: { $0.hasPrefix("Info.plist entries=") })
        else { throw HeartportError(.runtimeInvalid, "xdt.app is not signed with \(identifier), the hardened runtime and its Info.plist") }
        let exe = bundle.appendingPathComponent("Contents/MacOS/wine")
        let loader = runtime.appendingPathComponent(loaderPath)
        guard try entitlements(exe) == entitlements(loader) else {
            throw HeartportError(.runtimeInvalid, "xdt.app is entitled differently from the loader")
        }
        let plistData = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == identifier,
              plist["LSSupportsGameMode"] as? Bool == true,
              plist["LSApplicationCategoryType"] as? String == "public.app-category.simulation-games"
        else { throw HeartportError(.runtimeInvalid, "xdt.app's Info.plist does not declare Heartopia as a game") }
    }
}
