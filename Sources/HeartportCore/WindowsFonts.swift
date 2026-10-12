import Foundation

/// Fonts from macOS linked into the prefix's `C:\windows\Fonts` (docs/PHASE2.md "Prefix setup").
///
/// Unity's built-in "Arial" (used by the XD SDK's agreement dialog and other legacy uGUI Text)
/// carries no font data; UnityPlayer.dll finds it by scanning `C:\Windows\Fonts` itself, and Wine
/// leaves that folder empty, so such text draws nothing. Every Mac has these files; they are
/// linked, never copied or shipped.
public enum WindowsFonts {
    public struct Link: Sendable, Equatable {
        /// File name inside `windows/Fonts`.
        public var name: String
        /// Absolute path of the macOS file the link points at.
        public var source: String
    }

    /// The fonts to link. Add more here.
    public static let all: [Link] = [
        "Arial.ttf", "Arial Bold.ttf", "Arial Italic.ttf", "Arial Bold Italic.ttf", "Arial Unicode.ttf",
    ].map { Link(name: $0, source: "/System/Library/Fonts/Supplemental/\($0)") }

    /// Links that are missing (or dangling) in `fontsDir` and whose source exists. Fonts whose
    /// source is absent on this Mac are skipped. Reads files only.
    public static func pending(in fontsDir: URL, links: [Link] = all) -> [Link] {
        let fm = FileManager.default
        return links.filter { link in
            fm.fileExists(atPath: link.source)
                && !fm.fileExists(atPath: fontsDir.appendingPathComponent(link.name).path)
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
