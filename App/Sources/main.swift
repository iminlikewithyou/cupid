import AppKit

// Heartport.app: a thin window over HeartportCore (docs/PHASE2.md "App").
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
