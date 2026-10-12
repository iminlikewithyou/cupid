import AppKit
import HeartportCore
import SwiftUI

// The setup window: a hero header, a row of step dots, one card for the current step, and
// inline callouts for failures and notices. Presentation only; every action goes to AppModel.

/// Heartport's colours, taken from the app icon.
enum Brand {
    /// The icon's coral pink, used for the hero wash.
    static let pink = Color(nsColor: NSColor(srgbRed: 1.00, green: 0.47, blue: 0.56, alpha: 1))
    /// The controls' accent: a warm red that keeps white text legible, lifted a little in dark mode.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.98, green: 0.38, blue: 0.47, alpha: 1)
            : NSColor(srgbRed: 0.89, green: 0.24, blue: 0.35, alpha: 1)
    })
}

/// Reveals `url` in the Finder, or its nearest existing parent (the data folder may not exist yet).
@MainActor func revealInFinder(_ url: URL) {
    var target = url
    let fm = FileManager.default
    while !fm.fileExists(atPath: target.path), target.pathComponents.count > 1 {
        target = target.deletingLastPathComponent()
    }
    NSWorkspace.shared.activateFileViewerSelecting([target])
}

struct ContentView: View {
    /// The width is fixed; the height is a first guess until the content is measured.
    static let size = CGSize(width: 520, height: 480)
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.welcome {
                WelcomeView(model: model)
            } else if model.allSet {
                AllSetView(model: model)
            } else {
                VStack(spacing: 0) {
                    HeroHeader()
                        .padding(.top, 40) // clears the traffic lights
                    // Setup progress; gone once setup is complete.
                    if model.step != .ready {
                        StepDots(current: model.step)
                            .padding(.top, 24)
                            .padding(.horizontal, 8)
                    }
                    StepCard(model: model)
                        .padding(.top, 24)
                    Callouts(model: model)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // The window hugs this height in every state (AppModel.contentHeight).
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { model.contentHeight = $0 }
        .frame(width: Self.size.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { Backdrop(rich: model.welcome || model.allSet) }
        .ignoresSafeArea()
        .tint(Brand.accent)
    }
}

// MARK: - Hero

private struct Backdrop: View {
    /// The welcome screen's wash: deeper, over the full height, with a glow behind the icon.
    var rich = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if rich {
                LinearGradient(stops: [.init(color: Brand.pink.opacity(dark ? 0.40 : 0.46), location: 0),
                                       .init(color: Brand.pink.opacity(dark ? 0.16 : 0.18), location: 0.55),
                                       .init(color: Brand.pink.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Brand.pink.opacity(dark ? 0.30 : 0.34), .clear],
                               center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0, endRadius: 240)
            } else {
                LinearGradient(colors: [Brand.pink.opacity(dark ? 0.24 : 0.30), Brand.pink.opacity(0)],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.48))
                RadialGradient(colors: [Brand.pink.opacity(dark ? 0.16 : 0.20), .clear],
                               center: UnitPoint(x: 0.5, y: 0.12), startRadius: 0, endRadius: 220)
            }
        }
    }
}

private struct HeroHeader: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                .accessibilityHidden(true)
            Text("Heartport")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 8)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Step dots

private struct StepDots: View {
    let current: SetupStep?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(SetupStep.allCases, id: \.self) { step in
                if step != .runtime {
                    Capsule()
                        .fill(isDone(step) || step == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 9)
                        .padding(.horizontal, -12)
                }
                VStack(spacing: 6) {
                    dot(step)
                    Text(step.label)
                        .font(.caption.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? AnyShapeStyle(.tint) : isDone(step) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .fixedSize()
                }
                .frame(width: 56)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.label), \(step == current ? "current step" : isDone(step) ? "done" : "to do")")
            }
        }
    }

    private func isDone(_ step: SetupStep) -> Bool {
        guard let current else { return false }
        return step < current || (current == .ready && step == .ready)
    }

    @ViewBuilder private func dot(_ step: SetupStep) -> some View {
        if isDone(step) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Brand.accent)
                .frame(width: 20, height: 20)
        } else if step == current {
            ZStack {
                Circle().fill(Brand.accent.opacity(0.18)).frame(width: 28, height: 28)
                Circle().fill(Brand.accent).frame(width: 20, height: 20)
                Circle().fill(.white).frame(width: 7, height: 7)
            }
            .frame(width: 20, height: 20)
        } else {
            Circle()
                .strokeBorder(.tertiary, lineWidth: 1.5)
                .frame(width: 20, height: 20)
        }
    }
}

// MARK: - Step card

/// The card's material, edge and shadow (step card and welcome card).
private struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.07), radius: 16, y: 6)
    }
}

/// First run: one composition (icon, title, three facts, Get Started) instead of a step card.
private struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var short: Bool { SetupSpace.isShort(available: model.freeBytes) }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                .iconEntrance(appeared, reduceMotion: reduceMotion)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Welcome to Heartport")
                    .font(.system(size: 34, weight: .bold))
                Text("Heartopia ported to Mac")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .entrance(appeared, delay: 0.35, reduceMotion: reduceMotion)
            Text("Heartport sets up everything Heartopia needs on this Mac in a few steps. Two of them need a few clicks from you; the rest is automatic.")
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .entrance(appeared, delay: 0.5, reduceMotion: reduceMotion)
            HStack(alignment: .top, spacing: 16) {
                Fact("clock", "About 15 minutes, plus the game download")
                if short, let free = model.freeBytes {
                    Fact("exclamationmark.triangle.fill", "This Mac only has \(free / 1_000_000_000) GB free.", warning: true)
                } else {
                    Fact("internaldrive", "About \(SetupSpace.totalGB) GB of free space")
                }
                Fact("lock.shield", "Nothing else on your Mac changes")
            }
            .padding(.top, 32)
            .entrance(appeared, delay: 0.65, reduceMotion: reduceMotion)
            Button { model.getStarted() } label: {
                Text("Get Started").frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(short)
            .padding(.top, 32)
            .entrance(appeared, delay: 0.8, reduceMotion: reduceMotion)
        }
        .padding(.top, 56) // under the traffic lights
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        .task {
            // Start once the window is on screen and sized, so the entrance is seen.
            try? await Task.sleep(for: .milliseconds(200))
            appeared = true
        }
    }
}

/// Once, when setup is complete: the welcome screen's composition with one Play button.
private struct AllSetView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                .iconEntrance(appeared, reduceMotion: reduceMotion)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Heartport is ready")
                    .font(.system(size: 34, weight: .bold))
                Text("Heartopia is all set up")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .entrance(appeared, delay: 0.35, reduceMotion: reduceMotion)
            Text("From now on, opening Heartport starts Heartopia. Hold Option while opening it to reach Settings instead.")
                .font(.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .entrance(appeared, delay: 0.5, reduceMotion: reduceMotion)
            Button { model.play() } label: {
                Label("Play", systemImage: "play.fill").frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.busy)
            .padding(.top, 32)
            .entrance(appeared, delay: 0.65, reduceMotion: reduceMotion)
            Callouts(model: model)
                .frame(maxWidth: 420)
        }
        .padding(.top, 56) // under the traffic lights
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        .task {
            // Start once the window is on screen and sized, so the entrance is seen.
            try? await Task.sleep(for: .milliseconds(200))
            appeared = true
        }
    }
}

private struct Fact: View {
    let systemImage: String
    let text: String
    var warning = false
    init(_ systemImage: String, _ text: String, warning: Bool = false) {
        self.systemImage = systemImage; self.text = text; self.warning = warning
    }
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(height: 28)
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(warning ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// The welcome and all-set icon: fades in while it springs up from 80% (about 0.8 s).
    /// With Reduce Motion it only fades.
    func iconEntrance(_ shown: Bool, reduceMotion: Bool) -> some View {
        scaleEffect(shown || reduceMotion ? 1 : 0.8)
            .opacity(shown ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.5) : .spring(response: 0.75, dampingFraction: 0.62), value: shown)
    }

    /// The text, facts, and button after the icon: each fades in (and rises 8 pt unless Reduce
    /// Motion is on), staggered by `delay`; the last ends about 1.2 s after the window appears.
    func entrance(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .animation(.easeOut(duration: 0.4).delay(delay), value: shown)
    }
}

private struct CardAction {
    var title: String
    var systemImage: String?
    var large = false
    /// Return triggers it (off for actions that should not fire by accident).
    var isDefault = true
    var help: String?
    /// False keeps it visible but not pressable (besides while an operation runs).
    var enabled = true
    var action: () -> Void
}

private struct StepCard: View {
    @ObservedObject var model: AppModel
    private enum Focus: Hashable { case primary, secondary }
    @FocusState private var focus: Focus?

    var body: some View {
        // Absent sections (no details, no progress) take no space: the card hugs its content.
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    if finishingUp { ProgressView().controlSize(.small) }
                }
                if !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            details
            progress
            bottomRow
        }
        .modifier(CardChrome())
        // With keyboard navigation on, start on the action Return triggers, not the quiet one.
        .defaultFocus($focus, .primary)
        .task(id: model.phase) {
            // defaultFocus alone loses to the hosting view's first key view on macOS.
            try? await Task.sleep(for: .milliseconds(50))
            if primary?.isDefault == true { focus = .primary }
        }
    }

    // MARK: text

    /// TapTap or another program of ours is still open (ready.launcherOpen / .sessionBusy) and
    /// Heartport is about to close it (not when Update Game opened TapTap).
    private var finishingUp: Bool {
        model.shownActivity == nil && !model.updatingGame
            && (model.phase == .ready(.launcherOpen) || model.phase == .ready(.sessionBusy))
    }

    private var title: String {
        if let activity = model.shownActivity { return activity.title }
        switch model.phase {
        case nil: return "Checking this Mac"
        case .rosettaMissing?: return "Install Rosetta 2"
        case .runtime?: return "Install the game runtime"
        case .prefix(let exists)?: return exists ? "Update the Windows environment" : "Create the Windows environment"
        case .taptap?: return "Install TapTap"
        case .download(let d)?: return d.incomplete ? "Finish the download" : "Download Heartopia"
        case .ready(.gameRunning)?: return "Heartopia is running"
        case .ready(.launcherOpen)?, .ready(.sessionBusy)?:
            return model.updatingGame ? "TapTap is open" : "Finishing up\u{2026}"
        case .ready?: return "Ready to play"
        }
    }

    private var description: String {
        switch model.phase {
        case nil:
            return "Heartport is looking at what is already installed."
        case .rosettaMissing?:
            return "Heartopia is a Windows game for Intel processors, and Heartport runs it through Rosetta 2, Apple's translator. It isn't installed on this Mac yet."
        case .runtime?:
            return "Heartport installs the layer that lets Heartopia, a Windows game, run on this Mac."
        case .prefix(let exists)?:
            return exists
                ? "A few settings need updating."
                : "Next, Heartport sets up the Windows environment Heartopia runs in."
        case .taptap?:
            return "Heartopia comes from TapTap, a game launcher like Steam. Its installer needs a few clicks from you."
        case .download?:
            return "In TapTap, find Heartopia and click \u{201C}Download & Install\u{201D}."
        case .ready(.gameRunning)?:
            return "Heartopia is open in its own window."
        case .ready(.launcherOpen)?, .ready(.sessionBusy)?:
            // Update Game opened TapTap; Play closes it. Otherwise Heartport closes it by itself.
            return model.updatingGame ? "If TapTap offers a Heartopia update, run it. Then press Play." : ""
        case .ready(.idle)?:
            return ""
        }
    }

    // MARK: details

    @ViewBuilder private var details: some View {
        switch model.phase {
        case .rosettaMissing?:
            VStack(alignment: .leading, spacing: 8) {
                Button("Open Apple's Instructions") { model.openRosettaInstructions() }
                    .buttonStyle(.link)
                Text("Or run this in Terminal, then press Check Again:")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("softwareupdate --install-rosetta --agree-to-license")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        case .runtime?:
            VStack(alignment: .leading, spacing: 8) {
                DetailRow("clock", "One or two minutes")
                DetailRow("internaldrive", "About 1.5 GB")
            }
        case .prefix(let exists)?:
            if !exists { DetailRow("clock", "About a minute") }
        case .taptap(let installerRunning)?:
            VStack(alignment: .leading, spacing: 12) {
                NumberedStep(1, "globe", "Pick your language if the installer asks.")
                NumberedStep(2, "checkmark.circle",
                             "Click the circle next to \u{201C}I have read and agree to the above terms\u{201D}.")
                NumberedStep(3, "arrow.down.circle", "Click Install Now. Leave Custom Options as they are.")
                NumberedStep(4, "play.circle", "When it says Installation complete, press Launch.")
                if installerRunning {
                    StatusRow(ok: true, "The installer is open in its own window.")
                } else if model.report?.session.alive == true {
                    DetailRow("hourglass", "Heartport is finishing the previous step.")
                } else {
                    DetailRow("macwindow", "TapTap's installer opens in a separate window, \u{201C}Welcome to TapTap Setup\u{201D}.")
                }
            }
        case .download(let d)?:
            VStack(alignment: .leading, spacing: 12) {
                if !d.incomplete {
                    NumberedStep(1, "folder", "In the Install Path dialog keep the defaults and click Start Install.")
                    NumberedStep(2, "macwindow", "Leave TapTap open until the download finishes.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    downloadRows(d)
                }
            }
        case .ready(let state)?:
            if model.hud {
                ReadyStatus(model: model, state: state)
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func downloadRows(_ d: SetupPhase.Download) -> some View {
                if d.launcherRunning {
                    StatusRow(ok: true, "TapTap is open in its own window.")
                } else {
                    DetailRow("macwindow", "TapTap's window opens separately.")
                }
                if d.fraction == nil {
                    DetailRow("internaldrive", "The game is about 13 GB")
                }
                if d.incomplete {
                    StatusRow(ok: false, "Some game files are damaged. Use TapTap's verify, or Repair in the Heartport menu.")
                }
    }

    // MARK: progress

    @ViewBuilder private var progress: some View {
        if let activity = model.shownActivity {
            VStack(alignment: .leading, spacing: 6) {
                if let f = activity.fraction {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(activity.cancelling ? "Cancelling…" : activity.line.isEmpty ? " " : activity.line)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        } else if model.phase == nil {
            ProgressView().progressViewStyle(.linear)
        } else if case .download(let d)? = model.phase {
            DownloadProgress(download: d, eta: model.downloadETA)
        }
    }

    // MARK: buttons

    private var bottomRow: some View {
        HStack(spacing: 12) {
            secondaryButton
            Spacer(minLength: 0)
            if let primary {
                let button = Button(action: primary.action) {
                    if let image = primary.systemImage {
                        Label(primary.title, systemImage: image).frame(minWidth: primary.large ? 120 : 0)
                    } else {
                        Text(primary.title).frame(minWidth: primary.large ? 120 : 0)
                    }
                }
                .controlSize(primary.large ? .extraLarge : .large)
                .disabled(model.busy || !primary.enabled)
                .help(primary.help ?? "")
                .focused($focus, equals: .primary)
                if primary.isDefault {
                    button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    // A fallback (Restart TapTap while it downloads): available, not urged.
                    button.buttonStyle(.bordered)
                }
            }
        }
    }

    private var primary: CardAction? {
        switch model.phase {
        case nil:
            return nil
        case .rosettaMissing?:
            return CardAction(title: "Check Again") { model.refresh() }
        case .runtime?:
            return CardAction(title: "Set Up") { model.runSetup() }
        case .prefix(let exists)?:
            return CardAction(title: exists ? "Continue Setup" : "Continue") { model.runSetup() }
        case .taptap(let installerRunning)?:
            return installerRunning
                ? CardAction(title: "I've Installed It") { model.recheckTapTap() }
                : CardAction(title: "Launch Installer", enabled: model.report?.session.alive != true) { model.launchInstaller() }
        case .download(let d)?:
            return d.launcherRunning
                ? CardAction(title: "Restart TapTap", isDefault: false,
                             help: "If TapTap's window is blank, restart it with Heartport's settings.") {
                    model.openLauncherForDownload(restart: true)
                }
                : CardAction(title: "Open TapTap") { model.openLauncherForDownload(restart: false) }
        case .ready(.gameRunning(let pid))?:
            return CardAction(title: "Show Heartopia", large: true) { model.showHeartopia(pid: pid) }
        case .ready?:
            return CardAction(title: "Play", systemImage: "play.fill", large: true) { model.play() }
        }
    }

    /// Cancel while a cancellable step runs; "I've Installed It" before the TapTap installer is
    /// open; otherwise Show Logs, or Show in Finder before there are any logs.
    @ViewBuilder private var secondaryButton: some View {
        Group {
            if let activity = model.shownActivity, activity.cancellable {
                Button(activity.cancelling ? "Cancelling…" : "Cancel") { model.cancel() }
                    .disabled(activity.cancelling)
            } else if model.shownActivity == nil, case .taptap(false)? = model.phase {
                Button("I've Installed It") { model.recheckTapTap() }
            } else if model.hasLogs {
                Button("Show Logs") { model.showLogs() }
            } else {
                Button("Show in Finder") { if !model.previewing { revealInFinder(model.paths.dataRoot) } }
                    .help("Heartport's data folder")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .controlSize(.large)
        .focused($focus, equals: .secondary)
    }
}

// MARK: - Card parts

private struct DetailRow: View {
    let systemImage: String
    let text: String
    init(_ systemImage: String, _ text: String) { self.systemImage = systemImage; self.text = text }
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct StatusRow: View {
    let ok: Bool
    let text: String
    init(ok: Bool, _ text: String) { self.ok = ok; self.text = text }
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
        }
        .font(.footnote)
    }
}

private struct NumberedStep: View {
    let number: Int
    let systemImage: String
    let text: String
    init(_ number: Int, _ systemImage: String, _ text: String) {
        self.number = number; self.systemImage = systemImage; self.text = text
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20) // symbols differ in width; keep the text aligned
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DownloadProgress: View {
    let download: SetupPhase.Download
    let eta: TimeInterval?

    var body: some View {
        if let f = download.fraction {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: f)
                HStack {
                    Text("\(gb(download.bytesOnDisk ?? 0)) of \(gb(download.totalBytes ?? 0))")
                    Spacer()
                    Text(etaText ?? "\(Int((f * 100).rounded(.down)))%")
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        } else if let have = download.bytesOnDisk, have > 0 {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().progressViewStyle(.linear)
                Text("\(gb(have)) so far").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text("Waiting for the download to start.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    private var etaText: String? {
        guard let eta else { return nil }
        if eta < 60 { return "Less than a minute left" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = 1
        f.allowedUnits = eta < 3600 ? [.minute] : [.hour, .minute]
        return f.string(from: eta).map { "About \($0) left" }
    }
}

private struct ReadyStatus: View {
    @ObservedObject var model: AppModel
    let state: SetupPhase.Ready

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.hud {
                DetailRow("gauge.with.dots.needle.33percent", "Performance overlay on")
            }
        }
    }
}

// MARK: - Callouts

private struct Callouts: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.failure != nil || model.notice != nil {
            VStack(spacing: 8) {
                if let failure = model.failure {
                    Callout(text: failure, systemImage: "exclamationmark.octagon.fill", tint: .red,
                            showLogs: model.showLogs, dismiss: { model.failure = nil })
                }
                if let notice = model.notice {
                    Callout(text: notice, systemImage: "info.circle.fill", tint: .secondary,
                            showLogs: nil, dismiss: { model.notice = nil })
                }
            }
            .padding(.top, 16)
        }
    }
}

private struct Callout: View {
    let text: String
    let systemImage: String
    let tint: Color
    let showLogs: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(firstLine)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(text)
            if let showLogs {
                Button("Show Logs", action: showLogs).buttonStyle(.link)
            }
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
    }

    private var firstLine: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}

// MARK: - Settings

struct SettingsView: View {
    static let width: CGFloat = 380
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Performance overlay", isOn: Binding(get: { model.hud }, set: { model.setHUD($0) }))
            } footer: {
                Text("Shows frame rate, GPU time, and Game Mode status in a corner of Heartopia. Takes effect the next time the game starts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Data folder") {
                    Button("Show in Finder") { if !model.previewing { revealInFinder(model.paths.dataRoot) } }
                }
            } footer: {
                Text("Hold Option while opening Heartport to reach this window without starting the game.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Brand.accent)
    }
}
