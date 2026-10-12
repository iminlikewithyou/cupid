import Foundation

/// Fonts from macOS linked into the prefix's `C:\windows\Fonts` (docs/PHASE2.md "Prefix setup").
///
/// Unity's built-in "Arial" (used by the XD SDK's agreement dialog and other legacy uGUI Text)
/// carries no font data; UnityPlayer.dll finds it by scanning `C:\Windows\Fonts` itself, and Wine
/// leaves that folder empty, so such text draws nothing. Every Mac has these files; they are
/// linked, never copied or shipped.
///
/// Each link is also registered under HKLM `...\CurrentVersion\Fonts`, as a Windows installer
/// would. Wine registers only fonts outside `windows/Fonts` ("external" ones) there, and once the
/// same face is in `windows/Fonts` it drops the macOS copy's entry on the next boot. DirectWrite
/// (dlls/dwrite) builds the system collection from that key alone, so without our values TapTap's
/// Chromium lost Arial and Arial Unicode MS (missing-glyph boxes for "：" and CJK text).
public enum WindowsFonts {
    public struct Link: Sendable, Equatable {
        /// File name inside `windows/Fonts`.
        public var name: String
        /// Full face name from the file's name table (Wine names registry values after it).
        public var face: String
        /// Absolute path of the macOS file the link points at.
        public var source: String

        /// Value name under HKLM `...\CurrentVersion\Fonts`.
        public var registryValue: String { "\(face) (TrueType)" }

        /// `"<face> (TrueType)"="<file>"`: a bare file name, which dwrite and Windows resolve
        /// against `%WINDIR%\Fonts`. Wine's own font loader skips it (the face is already
        /// loaded from `windows/Fonts`), so GDI sees no duplicate.
        public var registrySeed: RegistrySeed {
            RegistrySeed(hive: .localMachine, key: RegistrySeeds.fontsKey, name: registryValue,
                         value: .string(name), policy: .whenAbsent)
        }

        /// `reg.exe delete` of Wine's own record of this face as an external (macOS) font, made
        /// by a boot before the link existed. Wine would delete that record on its next boot and
        /// take our value of the same name with it (win32u font.c update_external_font_keys).
        public var staleExternalDeleteArguments: [String] {
            ["reg.exe", "delete", "HKCU\\" + RegistrySeeds.wineExternalFontsKey, "/v", registryValue, "/f"]
        }
    }

    /// The fonts to link: file name in Supplemental and full face name. Add more here.
    public static let all: [Link] = [
        ("Arial.ttf", "Arial"),
        ("Arial Bold.ttf", "Arial Bold"),
        ("Arial Italic.ttf", "Arial Italic"),
        ("Arial Bold Italic.ttf", "Arial Bold Italic"),
        ("Arial Unicode.ttf", "Arial Unicode MS"),
    ].map { Link(name: $0.0, face: $0.1, source: "/System/Library/Fonts/Supplemental/\($0.0)") }

    /// Links that are missing (or dangling) in `fontsDir` and whose source exists. Fonts whose
    /// source is absent on this Mac are skipped. Reads files only.
    public static func pending(in fontsDir: URL, links: [Link] = all) -> [Link] {
        let fm = FileManager.default
        return links.filter { link in
            fm.fileExists(atPath: link.source)
                && !fm.fileExists(atPath: fontsDir.appendingPathComponent(link.name).path)
        }
    }

    /// Links whose registry value is absent from `systemReg` (system.reg) while the font is, or
    /// will be, in `fontsDir`. Reads files only.
    public static func unregistered(in fontsDir: URL, systemReg: RegFile?, links: [Link] = all) -> [Link] {
        let fm = FileManager.default
        return links.filter { link in
            (fm.fileExists(atPath: link.source) || fm.fileExists(atPath: fontsDir.appendingPathComponent(link.name).path))
                && !link.registrySeed.isSatisfied(by: systemReg)
        }
    }

    /// Creates the pending links (replacing a dangling link of the same name). Returns them.
    @discardableResult
    public static func create(in fontsDir: URL, links: [Link] = all) throws -> [Link] {
        let fm = FileManager.default
        let todo = pending(in: fontsDir, links: links)
        guard !todo.isEmpty else { return [] }
        try fm.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        for link in todo {
            let dest = fontsDir.appendingPathComponent(link.name)
            if (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil { try fm.removeItem(at: dest) }
            try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: link.source)
        }
        return todo
    }
}
