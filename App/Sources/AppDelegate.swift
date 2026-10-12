import AppKit
import CupidCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model: AppModel
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    override init() {
        let env = ProcessInfo.processInfo.environment
        // CUPID_DATA_ROOT picks another data root; CUPID_NO_AUTOPLAY=1 keeps the window up
        // in the ready state instead of starting the game.
        let paths = Paths.resolve()
        model = AppModel(paths: paths, autoLaunch: env["CUPID_NO_AUTOPLAY"] != "1")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        // CUPID_APPEARANCE=light|dark forces an appearance (for checking both looks).
        switch ProcessInfo.processInfo.environment["CUPID_APPEARANCE"]?.lowercased() {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        let size = ContentView.size
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Cupid"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(model: model))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(size)
        window.center()
        // Remembers the position only; the size is fixed.
        if window.setFrameAutosaveName("CupidSetupWindow") { window.setContentSize(size) }

        model.showWindow = { [weak self] in
            guard let self else { return }
            self.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        model.hideWindow = { [weak self] in self?.window.orderOut(nil) }
        model.resizeWindow = { [weak self] height, animated in
            guard let window = self?.window else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.height - height) > 0.5 else { return }
            // Keep the top edge where it is (the title bar stays under the pointer).
            let rect = NSRect(x: content.minX, y: content.maxY - height, width: content.width, height: height)
            window.setFrame(window.frameRect(forContentRect: rect), display: true, animate: animated)
        }
        model.windowIsVisible = { [weak self] in self?.window.isVisible == true }
        model.presentAlert = { [weak self] alert, done in
            if let window = self?.window, window.isVisible {
                alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
            } else {
                done(alert.runModal() == .alertFirstButtonReturn)
            }
        }
        let env = ProcessInfo.processInfo.environment
        if let name = env["CUPID_PREVIEW_PHASE"], !name.isEmpty {
            guard let preview = Preview.named(name) else {
                FileHandle.standardError.write(Data("CUPID_PREVIEW_PHASE: unknown phase \"\(name)\". One of: \(Preview.names.joined(separator: ", "))\n".utf8))
                exit(2)
            }
            model.showPreview(preview)
            if env["CUPID_PREVIEW_SETTINGS"] == "1" {
                // Queued after showPreview's window, so Settings ends up key.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.openSettings(nil) } }
            }
            if env["CUPID_PREVIEW_ABOUT"] == "1" {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.openAbout(nil) } }
            }
        } else {
            // Holding Option while opening skips the game and shows the window (Settings, Repair).
            if NSEvent.modifierFlags.contains(.option) { model.skipAutoLaunch() }
            model.start()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showWindow(); model.refresh() }
        return true
    }

    /// Free space may have changed while away (the welcome screen's Get Started depends on it).
    func applicationDidBecomeActive(_ notification: Notification) {
        if window?.isVisible == true { model.refresh() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Cupid")
        appMenu.addItem(item("About Cupid", #selector(openAbout(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettings(_:)), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Play", #selector(play(_:)), "p"))
        appMenu.addItem(item("Update Game", #selector(updateGame(_:))))
        appMenu.addItem(item("Reset Graphics…", #selector(resetGraphics(_:))))
        appMenu.addItem(item("Show Logs", #selector(showLogs(_:)), "l"))
        appMenu.addItem(item("Repair…", #selector(repair(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Uninstall…", #selector(uninstall(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Cupid", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Cupid", #selector(NSApplication.terminate(_:)), "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Cupid", #selector(showMain(_:)), "0"))
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(play(_:)):
            if case .ready? = model.phase { return !model.busy }
            return false
        case #selector(updateGame(_:)):
            return !model.busy && model.report?.taptap.launcherInstalled == true
        case #selector(resetGraphics(_:)):
            return !model.busy && model.report?.prefix.exists == true
        case #selector(repair(_:)), #selector(uninstall(_:)):
            return !model.busy
        default:
            return true
        }
    }

    @objc func showMain(_ sender: Any?) { model.showWindow(); model.refresh() }
    @objc func play(_ sender: Any?) { model.play() }
    @objc func updateGame(_ sender: Any?) { model.showWindow(); model.updateGame() }
    @objc func resetGraphics(_ sender: Any?) { model.resetGraphics() }
    @objc func showLogs(_ sender: Any?) { model.showLogs() }
    @objc func repair(_ sender: Any?) { model.repair() }
    @objc func uninstall(_ sender: Any?) { model.uninstall() }

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            // A controller, so the window follows the form's height (a grouped Form has no
            // intrinsic height for an NSHostingView alone).
            let host = NSHostingController(rootView: SettingsView(model: model))
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            settingsWindow = w
        }
        model.refresh()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func openAbout(_ sender: Any?) {
        if aboutWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: AboutView.width, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "About Cupid"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            // A controller, so the window follows the form's height (a grouped Form has no
            // intrinsic height for an NSHostingView alone).
            let host = NSHostingController(rootView: AboutView(model: model))
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            aboutWindow = w
        }
        model.refresh()
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
