// heartport-bench-testapp: a minimal MetalKit window for testing the bench tools.
// Presents a new frame at 60 Hz and blocks the render loop once every
// `stutterEvery` seconds for `stutterMs` milliseconds, so the analysis
// should report about 60 FPS and one stutter per interval.
//
// Usage: bench-testapp [seconds=12] [stutterEvery=2] [stutterMs=120]
import AppKit
import MetalKit

let args = CommandLine.arguments
let runSeconds = args.count > 1 ? Double(args[1]) ?? 12 : 12
let stutterEvery = args.count > 2 ? Double(args[2]) ?? 2 : 2
let stutterMs = args.count > 3 ? Double(args[3]) ?? 120 : 120

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let start = CACurrentMediaTime()
    var nextStutter: Double
    var frame = 0

    init(device: MTLDevice) {
        queue = device.makeCommandQueue()!
        nextStutter = stutterEvery
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let t = CACurrentMediaTime() - start
        if t >= nextStutter {
            nextStutter += stutterEvery
            usleep(useconds_t(stutterMs * 1000))
        }
        frame += 1
        let phase = Double(frame % 120) / 120
        view.clearColor = MTLClearColor(red: phase, green: 0.4, blue: 1 - phase, alpha: 1)
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer!

    func applicationDidFinishLaunching(_ note: Notification) {
        let device = MTLCreateSystemDefaultDevice()!
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), device: device)
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        renderer = Renderer(device: device)
        view.delegate = renderer
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Heartport bench test"
        window.contentView = view
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + runSeconds) {
            print("frames drawn: \(self.renderer.frame)")
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
