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
        relativePath + "/Contents/Resources/en.lproj/InfoPlist.strings",
        relativePath + "/Contents/_CodeSignature/CodeResources",
    ]
    /// The Dock labels a bundled application with the bundle's display name, which is its folder
    /// name ("xdt") unless the bundle has a localized display name: `LSHasLocalizedDisplayName`,
    /// a `CFBundleDisplayName` equal to the folder name, and the localized name in
    /// `InfoPlist.strings` (Finder's rule for localized app names). WINEMAC_APP_NAME only renames
    /// the running application (Cmd-Tab), not the Dock tile.
    public static let displayNameStrings = "Contents/Resources/en.lproj/InfoPlist.strings"
    /// The Dock icon, when there is one (`CFBundleIconFile`).
    public static let iconFile = "Contents/Resources/Heartopia.icns"

    /// Bumped whenever the generated bundle changes; an older bundle is regenerated.
    /// 1: identifier and game keys (no version key). 2: display name and icon.
    /// 3: localized display name, so the Dock says Heartopia instead of xdt.
    public static let bundleVersion = 3
    public static let versionKey = "HeartportBundleVersion"
    /// Where the icon came from: "game" (the exe's own icon), "heartport" (Heartport's icon),
    /// or "none".
    public static let iconSourceKey = "HeartportIconSource"
    /// The game's exe existed when the bundle was made; when it did not, the bundle is
    /// regenerated with the game's icon once it does.
    public static let iconFromGameTriedKey = "HeartportIconFromGameTried"

    /// Keys added to the loader's embedded Info.plist.
    public static func gameKeys(identifier: String = identifier) -> [String: Any] {
        [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Heartopia",
            // The folder name; the localized name is "Heartopia" (displayNameStrings).
            "CFBundleDisplayName": "xdt",
            "LSHasLocalizedDisplayName": true,
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "wine",
            "LSApplicationCategoryType": "public.app-category.simulation-games",
            "LSSupportsGameMode": true,
            "GCSupportsGameMode": true, // the key's name on macOS 14 and 15
            "NSLocalNetworkUsageDescription": "Heartopia receives your sign-in from your web browser on this Mac.",
            // Kept: without a usage string, TCC kills a process that opens an input device.
            "NSMicrophoneUsageDescription": "Heartopia uses the microphone only if you turn on voice chat in the game.",
            versionKey: bundleVersion,
        ]
    }

    /// Heartport's own icon, for a game exe without a usable icon: inside the app
    /// (Contents/Resources/AppIcon.icns, also next to the CLI in Contents/Helpers), or a
    /// checkout's build/AppIcon.icns.
    public static func fallbackIconCandidates(executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")) -> [URL] {
        var out: [URL] = []
        if let main = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { out.append(main) }
        let exeDir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        out.append(exeDir.appendingPathComponent("../Resources/AppIcon.icns").standardizedFileURL)
        var dir = exeDir
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                out.append(dir.appendingPathComponent("build/AppIcon.icns"))
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        return out
    }

    public static func defaultFallbackIcon() -> URL? {
        fallbackIconCandidates().first { FileManager.default.fileExists(atPath: $0.path) }
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

    /// Create the bundle inside `runtime`. Fails if it exists. Its icon is the largest icon of
    /// `gameExe` drawn on the macOS icon grid, else a copy of `fallbackIcon`, else none.
    public static func create(runtime: URL, minimumMacOS: String = "15.0", identity: String = "-",
                              identifier: String = identifier, gameExe: URL? = nil,
                              fallbackIcon: URL? = defaultFallbackIcon()) throws {
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
            let gameExeExists = gameExe.map { fm.fileExists(atPath: $0.path) } ?? false
            info[iconFromGameTriedKey] = gameExeExists
            var source = "none"
            let icon = bundle.appendingPathComponent(iconFile)
            if gameExeExists, let gameExe, let image = PEIcon.largestImage(exe: gameExe) {
                try fm.createDirectory(at: icon.deletingLastPathComponent(), withIntermediateDirectories: true)
                try MacIcon.writeICNS(image, to: icon)
                source = "game"
            } else if let fallbackIcon, fm.fileExists(atPath: fallbackIcon.path) {
                try fm.createDirectory(at: icon.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: fallbackIcon, to: icon)
                source = "heartport"
            }
            info[iconSourceKey] = source
            if source != "none" { info["CFBundleIconFile"] = "Heartopia" }
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            let strings = bundle.appendingPathComponent(displayNameStrings)
            try fm.createDirectory(at: strings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\"CFBundleDisplayName\" = \"Heartopia\";\n\"CFBundleName\" = \"Heartopia\";\n".utf8).write(to: strings)
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
            let expected = addedFiles + (source == "none" ? [] : [relativePath + "/" + iconFile])
            guard added == expected.sorted() else {
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

    /// The Info.plist of an existing xdt.app (nil when absent or unreadable).
    public static func installedInfo(runtime: URL) -> [String: Any]? {
        let url = runtime.appendingPathComponent(relativePath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// CFBundleIdentifier of an existing xdt.app (nil when absent or unreadable).
    public static func installedIdentifier(runtime: URL) -> String? {
        installedInfo(runtime: runtime)?["CFBundleIdentifier"] as? String
    }

    /// Why an existing xdt.app should be regenerated: another identifier (pre-rename), an older
    /// bundle version, or it was made before the game's exe (and with it the game's icon)
    /// existed. Nil when it is current or absent. Reads only the Info.plist (cheap).
    public static func staleReason(runtime: URL, gameExe: URL) -> String? {
        guard let info = installedInfo(runtime: runtime) else { return nil }
        let found = info["CFBundleIdentifier"] as? String
        if found != identifier { return "identifier \(found ?? "none") -> \(identifier)" }
        let version = (info[versionKey] as? Int) ?? 1
        if version != bundleVersion { return "bundle version \(version) -> \(bundleVersion)" }
        if info[iconFromGameTriedKey] as? Bool != true, FileManager.default.fileExists(atPath: gameExe.path) {
            return "the game's icon is available now"
        }
        return nil
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
