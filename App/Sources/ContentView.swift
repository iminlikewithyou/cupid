import AppKit
import HeartportCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.semibold))
                    Text("Heartopia on Apple silicon").font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            if let activity = model.activity {
                ActivityView(activity: activity, cancel: model.cancel)
            } else {
                phaseView
            }
            Spacer(minLength: 0)
            if let failure = model.failure {
                Label { Text(failure).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    .font(.callout)
            }
            if let notice = model.notice {
                Label { Text(notice).textSelection(.enabled) } icon: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                    .font(.callout)
            }
        }
        .padding(22)
        .frame(width: 560, height: 420, alignment: .topLeading)
    }

    var title: String {
        switch model.phase {
        case nil: "Checking…"
        case .rosettaMissing?: "Rosetta is needed"
        case .runtime?: "Install the Windows runtime"
        case .prefix?: "Set up the Windows environment"
        case .taptap?: "Install TapTap"
        case .download?: "Download Heartopia"
        case .ready(.gameRunning)?: "Heartopia is running"
        case .ready?: "Ready"
        }
    }

    @ViewBuilder var phaseView: some View {
        switch model.phase {
        case nil:
            ProgressView().controlSize(.small)
        case .rosettaMissing?:
            Text("Heartopia is a Windows game for Intel processors. Heartport runs it with Rosetta 2, Apple's translator, which is not installed on this Mac.")
            Text("Install it by following Apple's instructions (or in Terminal: softwareupdate --install-rosetta --agree-to-license), then check again.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Apple's Instructions") { model.openRosettaInstructions() }
                Button("Check Again") { model.refresh() }.keyboardShortcut(.defaultAction)
            }
        case .runtime?:
            Text("Heartport installs a Wine runtime (Recall 1.3.0: Wine 11 with DXMT for Metal) into its data folder. It takes about 1.5 GB and a minute or two.")
            Text(model.paths.dataRoot.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Set Up") { model.runSetup() }.keyboardShortcut(.defaultAction)
        case .prefix(let exists)?:
            Text(exists ? "The Windows environment needs a few settings applied (Windows 10 mode, Retina mode off, Heartport's graphics defaults)."
                        : "Next, Heartport creates the Windows environment Heartopia runs in. This takes about a minute.")
            Button(exists ? "Continue Setup" : "Set Up") { model.runSetup() }.keyboardShortcut(.defaultAction)
        case .taptap(let installerRunning)?:
            TapTapInstallView(model: model, installerRunning: installerRunning)
        case .download(let d)?:
            DownloadView(model: model, download: d)
        case .ready(let state)?:
            ReadyView(model: model, state: state)
        }
    }
}

struct ActivityView: View {
    let activity: Activity
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(activity.title).font(.headline)
            if let f = activity.fraction {
                ProgressView(value: f)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(activity.line.isEmpty ? " " : activity.line)
                .font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            if activity.cancellable {
                Button(activity.cancelling ? "Cancelling…" : "Cancel", action: cancel).disabled(activity.cancelling)
            }
        }
    }
}

struct TapTapInstallView: View {
    @ObservedObject var model: AppModel
    let installerRunning: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heartopia is distributed through the TapTap launcher. Its installer opens a small window titled \u{201C}Welcome to TapTap Setup\u{201D}: a TapTap logo over a picture of a town, a grey Install Now button, Terms of Service and Privacy Policy links, and \u{201C}Custom Options\u{201D} at the bottom right.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Click the circle next to \u{201C}I have read and agree to the above terms\u{201D} at the bottom left. This accepts TapTap's terms; it is your decision.")
                Text("2. Click Install Now. Leave Custom Options as they are.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .font(.callout)
            HStack {
                if installerRunning {
                    Text("The installer is open.").foregroundStyle(.secondary)
                } else {
                    Button("Launch Installer") { model.launchInstaller() }.keyboardShortcut(.defaultAction)
                }
                Button("I've Installed It") { model.recheckTapTap() }
            }
        }
    }
}

struct DownloadView: View {
    @ObservedObject var model: AppModel
    let download: SetupPhase.Download
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("In TapTap, sign in if it asks, find Heartopia and click \u{201C}Download & Install\u{201D} (about 13 GB). Keep the default location and keep TapTap open until the download finishes.")
                .fixedSize(horizontal: false, vertical: true)
            if let f = download.fraction {
                ProgressView(value: f)
                Text("\(Operations.bytes(download.bytesOnDisk ?? 0)) of \(Operations.bytes(download.totalBytes ?? 0)) (\(Int((f * 100).rounded(.down)))%)")
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            } else if let have = download.bytesOnDisk, have > 0 {
                ProgressView().progressViewStyle(.linear)
                Text("\(Operations.bytes(have)) so far").font(.callout.monospaced()).foregroundStyle(.secondary)
            } else {
                Text("Not started yet.").foregroundStyle(.secondary)
            }
            if download.incomplete {
                Text("All files are present but some differ from TapTap's manifest. Use TapTap's verify, or Repair in the Heartport menu.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                if download.launcherRunning {
                    Text("TapTap is open.").foregroundStyle(.secondary)
                    Button("Restart TapTap") { model.openLauncherForDownload(restart: true) }
                        .help("If TapTap's window is blank, restart it with Heartport's settings.")
                } else {
                    Button("Launch TapTap to Download Heartopia") { model.openLauncherForDownload(restart: false) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

struct ReadyView: View {
    @ObservedObject var model: AppModel
    let state: SetupPhase.Ready
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .idle:
                Text("Heartopia is installed. Heartport starts it whenever you open the app.")
                Button("Play") { model.play() }.keyboardShortcut(.defaultAction).controlSize(.large)
            case .gameRunning(let pid):
                Text("Heartopia is already running.")
                Button("Show Heartopia") { model.showHeartopia(pid: pid) }.keyboardShortcut(.defaultAction).controlSize(.large)
            case .launcherOpen:
                Text("Heartopia is installed. The TapTap launcher is still open; it closes when the game starts.")
                Button("Play") { model.play() }.keyboardShortcut(.defaultAction).controlSize(.large)
            case .sessionBusy:
                Text("Heartopia is installed. Another Windows program from Heartport is still running; it closes when the game starts.")
                Button("Play") { model.play() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Toggle("Show the Metal performance HUD in Heartopia", isOn: Binding(get: { model.hud }, set: { model.setHUD($0) }))
            Text("Frame rate, GPU time and Game Mode status in the game's corner. Takes effect the next time Heartopia starts.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Data folder") {
                Text(model.paths.dataRoot.path).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
