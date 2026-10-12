import Foundation

/// The `[xdt.exe]` DXMT profile, written to `<data>/dxmt.conf` before each launch.
/// Identical to Resources/config/dxmt.conf (a test enforces it).
public enum DxmtConfig {
    public static let template = """
    [xdt.exe]
    d3d11.releaseShaderIR = True
    d3d11.preferredMaxFrameRate = 60
    d3d11.shaderCompilerThreads = 8
    d3d11.shaderCompilerNormalPriority = True
    d3d11.metalSpatialUpscaleFactor = 2.0
    dxgi.maxFrameLatency = 1
    dxgi.presentPacing = True
    dxgi.presentPacingMode = 3
    dxgi.presentPacingTargetUs = 1000
    dxgi.sharpPresentation = True

    """

    /// Writes the profile if the file differs. Returns true when it wrote.
    @discardableResult
    public static func write(to url: URL, contents: String = template) throws -> Bool {
        if let current = try? String(contentsOf: url, encoding: .utf8), current == contents { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return true
    }

    public static func isCurrent(at url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8)) == template
    }
}
