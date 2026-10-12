import Foundation

/// Heartport's own log (`logs/heartport.log`) and log-file housekeeping.
public enum Logs {
    public static func url(_ paths: Paths, _ name: String) -> URL { paths.logs.appendingPathComponent(name) }
    public static func heartport(_ paths: Paths) -> URL { url(paths, "heartport.log") }
    public static func game(_ paths: Paths) -> URL { url(paths, "game.log") }
    public static func winePrefix(_ paths: Paths) -> URL { url(paths, "wine-prefix.log") }
    public static func installer(_ paths: Paths) -> URL { url(paths, "taptap-installer.log") }
    public static func launcher(_ paths: Paths) -> URL { url(paths, "taptap-launcher.log") }
    public static func stop(_ paths: Paths) -> URL { url(paths, "stop.log") }
    /// Marker: the first launch logged DXMT at info level.
    public static func dxmtInfoMarker(_ paths: Paths) -> URL { url(paths, ".dxmt-info-done") }

    static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Append a timestamped line to logs/heartport.log (best effort).
    public static func append(_ paths: Paths, _ line: String) {
        guard let handle = try? ProcessRunner.appendHandle(heartport(paths)) else { return }
        defer { try? handle.close() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? handle.write(contentsOf: Data("\(stamp) \(line)\n".utf8))
    }

    /// Rotate `<name>.log` to `<name>.<yyyyMMdd-HHmmss>.log`, keeping the newest `keep` rotations.
    @discardableResult
    public static func rotate(_ log: URL, keep: Int = 10, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        let dir = log.deletingLastPathComponent()
        let base = log.deletingPathExtension().lastPathComponent
        var rotated: URL?
        if fm.fileExists(atPath: log.path) {
            var target = dir.appendingPathComponent("\(base).\(stampFormat.string(from: now)).log")
            var n = 1
            while fm.fileExists(atPath: target.path) {
                target = dir.appendingPathComponent("\(base).\(stampFormat.string(from: now))-\(n).log"); n += 1
            }
            try fm.moveItem(at: log, to: target)
            rotated = target
        }
        let pattern = #"^"# + NSRegularExpression.escapedPattern(for: base) + #"\.\d{8}-\d{6}(-\d+)?\.log$"#
        let old = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.range(of: pattern, options: .regularExpression) != nil }.sorted() ?? []
        for name in old.dropLast(keep) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        return rotated
    }

    /// The last `lines` lines of a text file.
    public static func tail(_ url: URL, lines: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = min(size, UInt64(max(lines, 1)) * 400 + 4096)
        try? handle.seek(toOffset: size - chunk)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines + 1).joined(separator: "\n")
    }
}
