// make-icon.swift OUT.iconset: draws Heartport's placeholder icon (a white heart on a rounded
// pink-to-coral square) at every iconset size. Original drawing; no game or TapTap artwork.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func heart(in r: NSRect) -> NSBezierPath {
    let p = NSBezierPath()
    let w = r.width, h = r.height, x = r.minX, y = r.minY
    p.move(to: NSPoint(x: x + w * 0.5, y: y + h * 0.08))
    p.curve(to: NSPoint(x: x, y: y + h * 0.66), controlPoint1: NSPoint(x: x + w * 0.32, y: y + h * 0.26), controlPoint2: NSPoint(x: x, y: y + h * 0.42))
    p.curve(to: NSPoint(x: x + w * 0.5, y: y + h * 0.80), controlPoint1: NSPoint(x: x, y: y + h * 0.98), controlPoint2: NSPoint(x: x + w * 0.42, y: y + h * 1.0))
    p.curve(to: NSPoint(x: x + w, y: y + h * 0.66), controlPoint1: NSPoint(x: x + w * 0.58, y: y + h * 1.0), controlPoint2: NSPoint(x: x + w, y: y + h * 0.98))
    p.curve(to: NSPoint(x: x + w * 0.5, y: y + h * 0.08), controlPoint1: NSPoint(x: x + w, y: y + h * 0.42), controlPoint2: NSPoint(x: x + w * 0.68, y: y + h * 0.26))
    p.close()
    return p
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let square = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(starting: NSColor(srgbRed: 1.00, green: 0.55, blue: 0.69, alpha: 1),
               ending: NSColor(srgbRed: 0.98, green: 0.38, blue: 0.42, alpha: 1))!.draw(in: square, angle: -90)
    let hs = body.width * 0.58
    let h = heart(in: NSRect(x: body.midX - hs / 2, y: body.midY - hs * 0.47, width: hs, height: hs * 0.92))
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.18)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.025
    shadow.set()
    NSColor.white.setFill()
    h.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(out.path)
