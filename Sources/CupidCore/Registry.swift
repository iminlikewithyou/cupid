import Foundation

/// A parsed Wine registry file (`user.reg`, `system.reg`). Read-only: Cupid writes the
/// registry only through `wine reg.exe add`, never by editing these files.
public struct RegFile: Sendable {
    /// Lower-cased key path (single backslashes) -> lower-cased value name -> raw value text.
    public private(set) var keys: [String: [String: String]] = [:]

    public init(text: String) {
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                guard let close = Self.closingBracket(line) else { current = nil; continue }
                let escaped = String(line[line.index(after: line.startIndex)..<close])
                let key = Self.unescape(escaped).lowercased()
                current = key
                if keys[key] == nil { keys[key] = [:] }
                continue
            }
            guard let key = current, let (name, value) = Self.parseValue(line) else { continue }
            keys[key, default: [:]][name.lowercased()] = value
        }
    }

    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(text: String(decoding: data, as: UTF8.self))
    }

    public func hasKey(_ key: String) -> Bool { keys[key.lowercased()] != nil }

    public func value(_ key: String, _ name: String) -> String? {
        keys[key.lowercased()]?[name.lowercased()]
    }

    public func dword(_ key: String, _ name: String) -> UInt32? {
        guard let raw = value(key, name), raw.lowercased().hasPrefix("dword:") else { return nil }
        return UInt32(raw.dropFirst(6), radix: 16)
    }

    public func string(_ key: String, _ name: String) -> String? {
        guard let raw = value(key, name), raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return nil }
        return Self.unescape(String(raw.dropFirst().dropLast()))
    }

    static func closingBracket(_ line: String) -> String.Index? {
        var i = line.index(after: line.startIndex)
        while i < line.endIndex {
            if line[i] == "\\" { i = line.index(after: i); if i < line.endIndex { i = line.index(after: i) }; continue }
            if line[i] == "]" { return i }
            i = line.index(after: i)
        }
        return nil
    }

    /// `"name"=value` or `@=value`; the name with its escapes removed.
    static func parseValue(_ line: String) -> (String, String)? {
        if line.hasPrefix("@=") { return ("", String(line.dropFirst(2))) }
        guard line.hasPrefix("\"") else { return nil }
        var name = ""
        var i = line.index(after: line.startIndex)
        while i < line.endIndex {
            let c = line[i]
            if c == "\\" {
                let n = line.index(after: i)
                guard n < line.endIndex else { return nil }
                name.append(line[n]); i = line.index(after: n); continue
            }
            if c == "\"" { break }
            name.append(c); i = line.index(after: i)
        }
        guard i < line.endIndex else { return nil }
        let rest = line[line.index(after: i)...]
        guard rest.hasPrefix("=") else { return nil }
        return (name, String(rest.dropFirst()))
    }

    static func unescape(_ s: String) -> String {
        var out = "", escaping = false
        for c in s {
            if escaping { out.append(c); escaping = false } else if c == "\\" { escaping = true } else { out.append(c) }
        }
        return out
    }
}

/// One registry value Cupid seeds (docs/PHASE2.md "Registry seeds").
public struct RegistrySeed: Sendable, Equatable, Hashable {
    public enum Value: Sendable, Equatable, Hashable {
        case dword(UInt32)
        case string(String)
    }
    public enum Hive: String, Sendable, Equatable, Hashable {
        /// HKCU, stored in user.reg.
        case currentUser = "HKCU"
        /// HKLM, stored in system.reg.
        case localMachine = "HKLM"
    }
    public enum Policy: Sendable, Equatable, Hashable {
        /// Applied only when the value is absent, so later in-game changes are kept.
        case whenAbsent
        /// Applied whenever the value differs.
        case enforce
    }

    public let hive: Hive
    /// Key path relative to the hive.
    public let key: String
    public let name: String
    public let value: Value
    public let policy: Policy

    public init(hive: Hive = .currentUser, key: String, name: String, value: Value, policy: Policy) {
        self.hive = hive; self.key = key; self.name = name; self.value = value; self.policy = policy
    }

    /// Arguments after `wine`: `reg.exe add "HKCU\..." /v NAME /t TYPE /d DATA /f`.
    public var regAddArguments: [String] {
        let (type, data): (String, String) = switch value {
        case .dword(let v): ("REG_DWORD", String(v))
        case .string(let s): ("REG_SZ", s)
        }
        return ["reg.exe", "add", hive.rawValue + "\\" + key, "/v", name, "/t", type, "/d", data, "/f"]
    }

    /// `reg` is the file of the seed's hive (user.reg or system.reg).
    public func isSatisfied(by reg: RegFile?) -> Bool {
        guard let reg else { return false }
        switch (policy, value) {
        case (.whenAbsent, _): return reg.value(key, name) != nil
        case (.enforce, .dword(let v)): return reg.dword(key, name) == v
        case (.enforce, .string(let s)): return reg.string(key, name) == s
        }
    }
}

public enum RegistrySeeds {
    public static let macDriverKey = #"Software\Wine\Mac Driver"#
    public static let gameKey = #"Software\xd\Heartopia"#
    /// HKLM: the installed-fonts list (Windows NT); dwrite's system collection reads only this.
    public static let fontsKey = #"Software\Microsoft\Windows NT\CurrentVersion\Fonts"#
    /// HKCU: Wine's record of the macOS fonts it registered itself.
    public static let wineExternalFontsKey = #"Software\Wine\Fonts\External Fonts"#

    /// Retina mode stays off for everything: the TapTap installer ignores clicks at Y, the
    /// launcher is sized wrong at Y, and the game's full-panel mode needs N.
    public static let retinaMode = RegistrySeed(key: macDriverKey, name: "RetinaMode", value: .string("N"), policy: .enforce)

    /// Heartopia's PlayerPrefs (hashed names), all REG_DWORD. No resolution or screen-size
    /// values: with them the game asked "Resolution switched to 3840x2160@120 FPS. Apply?" on
    /// its first launch; without them it picks the desktop size itself (seen on fresh installs).
    /// Frame rate is capped in dxmt.conf instead.
    public static let gamePrefs: [RegistrySeed] = [
        ("UnityGraphicsQuality_h1669003810", 1),            // High
        ("QualityLevel_h4026849054", 1),
        ("NewUserGraphicsQualityString_h2322609765", 1),    // stops the first-run auto-pick of Ultra
        ("ORIGIN_QUALITY_h3319388771", 1),
        ("RenderScaleString_h868707778", 2),                // High
        ("ShaderQualityString_h3156345780", 1),             // Medium
        ("FXAAEnabledString_h219820651", 0),
        ("BloomEnabledString_h1769754614", 1),
        ("PcUICanvasScale_h3623448666", 1),                 // 85%
        ("SoundVolumeString_h3855669083", 25),              // music 25%
        ("SoundEffectVolume_h2094452281", 50),              // effects 50%
        ("Screenmanager Fullscreen mode_h3630240806", 1),   // fullscreen window
        ("CameraSensitivity_h1088127345", 10),            // Camera sensitivity 10, the game's default is 8
        ("SeaCameraSensitivity_h405975366", 10),          // Camera sensitivity 10, the game's default is 8
    ].map { RegistrySeed(key: gameKey, name: $0.0, value: .dword($0.1), policy: .whenAbsent) }

    /// The HKCU seeds (what Reset graphics re-applies).
    public static var all: [RegistrySeed] { [retinaMode] + gamePrefs }

    /// The HKLM font registrations, one per `WindowsFonts.all` link (applied by the prefix's
    /// font step, see `WindowsFonts.unregistered`).
    public static var fonts: [RegistrySeed] { WindowsFonts.all.map(\.registrySeed) }

    /// Seeds that still need `reg.exe add`. `force` (Reset graphics) re-applies every one.
    public static func pending(in reg: RegFile?, force: Bool = false) -> [RegistrySeed] {
        force ? all : all.filter { !$0.isSatisfied(by: reg) }
    }

    /// `system.reg` says Windows 10 (what `winecfg -v win10` sets).
    public static func isWindows10(_ systemReg: RegFile?) -> Bool {
        systemReg?.string(#"Software\Microsoft\Windows NT\CurrentVersion"#, "ProductName") == "Microsoft Windows 10"
            && systemReg?.string(#"Software\Microsoft\Windows NT\CurrentVersion"#, "CurrentBuild") == "19045"
    }
}
