import AppKit
import CupidCore
import SwiftUI

/// The About window: the app, the installed game and runtime, macOS, and credits.
struct AboutView: View {
    static let width: CGFloat = 420
    @ObservedObject var model: AppModel

    private static let info = Bundle.main.infoDictionary ?? [:]

    /// "Version 0.2.0 (1)", or a plain label when running outside the app bundle.
    static var appVersion: String {
        guard let short = info["CFBundleShortVersionString"] as? String else { return "Development build" }
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty { return "Version \(short) (\(build))" }
        return "Version \(short)"
    }

    /// Info.plist CupidProjectURL, when set.
    static var projectURL: URL? {
        (info["CupidProjectURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    /// Contents/Resources/Licenses of the app bundle.
    static var licensesFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Licenses", isDirectory: true)
    }

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        var size = 0
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.osversion", &buf, &size, nil, 0) == 0 {
                text += " (\(String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))"
            }
        }
        return text
    }

    /// The bundled runtime carries FFmpeg and GStreamer (Cupid's builds from 20261012.3).
    static var runtimeHasVideo: Bool {
        guard let lic = licensesFolder else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: lic.appendingPathComponent("native/ffmpeg").path)
            && fm.fileExists(atPath: lic.appendingPathComponent("native/gstreamer").path)
    }

    static var credits: String {
        let video = runtimeHasVideo ? ", plus GStreamer and FFmpeg for video" : ""
        return "Cupid is built on Recall by AsherJN (Apache License 2.0). Its runtime is Wine, built from "
            + "CodeWeavers\u{2019} CrossOver source, with DXMT (3Shain\u{2019}s Direct3D-to-Metal layer, in "
            + "NerRobDog\u{2019}s fork) and Apple\u{2019}s Game Porting Toolkit library\(video). "
            + "Heartopia is XD\u{2019}s game, downloaded through TapTap. Cupid is an independent project, "
            + "not affiliated with XD, TapTap, Apple, or CodeWeavers."
    }

    private var gameVersion: String {
        guard let game = model.report?.game, let version = game.version else { return "Not installed" }
        return version + (game.build.map { " (build \($0))" } ?? "")
    }

    private var runtimeVersion: String {
        model.report?.runtime.installedVersion ?? model.paths.runtimeVersion
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Heartopia", value: gameVersion)
                LabeledContent("Runtime", value: runtimeVersion)
                LabeledContent("macOS", value: Self.macOSVersion)
            } header: {
                header
            } footer: {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Self.credits)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Show Licences") {
                            if !model.previewing, let lic = Self.licensesFolder { revealInFinder(lic) }
                        }
                        Spacer()
                        if let url = Self.projectURL {
                            Link("Project on GitHub", destination: url)
                                .font(.footnote)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Brand.accent)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Cupid")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Heartopia ported to Mac")
                .font(.body)
                .foregroundStyle(.secondary)
            Text(Self.appVersion)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .textCase(nil)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 10)
    }
}
