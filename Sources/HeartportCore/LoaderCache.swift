import Foundation

/// CrossOver's Wine loader keeps per-program hard links of itself in the Darwin per-user
/// temporary directory (`winetemp-<inode>-<size>-<mtime>-<nsec>/`) so each Windows program
/// gets its own Dock name, with an `ntdll.so` symlink to the runtime's absolute path.
/// The key survives a move of the runtime (inode, size and mtime are unchanged) but the
/// symlink does not, and Wine then fails with "could not load ntdll.so". This removes
/// cache entries whose link no longer resolves.
public enum LoaderCache {
    /// The directory the loader uses: `confstr(_CS_DARWIN_USER_TEMP_DIR)`.
    public static func darwinUserTempDir() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    /// Removes every `winetemp-*` entry in `tempDir` whose `ntdll.so` symlink is dangling.
    /// Returns the removed directories. Entries without an `ntdll.so` link are left alone.
    @discardableResult
    public static func removeStaleEntries(in tempDir: URL? = darwinUserTempDir()) -> [URL] {
        guard let tempDir else { return [] }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: tempDir.path) else { return [] }
        var removed: [URL] = []
        for name in names where name.hasPrefix("winetemp-") {
            let dir = tempDir.appendingPathComponent(name, isDirectory: true)
            let link = dir.appendingPathComponent("ntdll.so")
            guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let resolved = target.hasPrefix("/") ? target : dir.appendingPathComponent(target).path
            if fm.fileExists(atPath: resolved) { continue }
            if (try? fm.removeItem(at: dir)) != nil { removed.append(dir) }
        }
        return removed
    }
}
