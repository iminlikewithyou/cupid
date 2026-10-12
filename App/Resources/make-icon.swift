// make-icon.swift OUT.iconset: draws Heartport's icon at every iconset size: a rounded square on
// Apple's macOS icon grid with a coral-pink to warm-red vertical gradient, a white heart with a
// soft inner shadow, and a short white "port" bar beneath it. Original drawing; no game or
// TapTap artwork.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// A heart filling `r` (its point at the bottom; AppKit's y axis points up).
func heart(in r: NSRect) -> NSBezierPath {
    let p = NSBezierPath()
    let w = r.width, h = r.height, x = r.minX, y = r.minY
    func pt(_ u: CGFloat, _ v: CGFloat) -> NSPoint { NSPoint(x: x + w * u, y: y + h * v) }
    p.move(to: pt(0.5, 0))
    p.curve(to: pt(0, 0.62), controlPoint1: pt(0.30, 0.18), controlPoint2: pt(0, 0.36))
    p.curve(to: pt(0.5, 0.80), controlPoint1: pt(0, 0.96), controlPoint2: pt(0.40, 1.04))
    p.curve(to: pt(1, 0.62), controlPoint1: pt(0.60, 1.04), controlPoint2: pt(1, 0.96))
    p.curve(to: pt(0.5, 0), controlPoint1: pt(1, 0.36), controlPoint2: pt(0.70, 0.18))
    p.close()
    return p
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(px)
    let u = s / 1024 // one point of the 1024 grid

    // Apple's macOS grid: an 824x824 body centred on the 1024 canvas, corner radius 185.4,
    // with a soft drop shadow inside the 100-point margin.
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let square = NSBezierPath(roundedRect: body, xRadius: 185.4 * u, yRadius: 185.4 * u)
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor(white: 0, alpha: 0.28)
    drop.shadowOffset = NSSize(width: 0, height: -10 * u)
    drop.shadowBlurRadius = 20 * u
    drop.set()
    srgb(0.93, 0.30, 0.38).setFill()
    square.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Body: coral pink at the top to warm red at the bottom, with a faint top sheen.
    NSGradient(starting: srgb(1.00, 0.53, 0.58), ending: srgb(0.88, 0.19, 0.27))!.draw(in: square, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    square.addClip()
    NSGradient(starting: NSColor(white: 1, alpha: 0.20), ending: NSColor(white: 1, alpha: 0))!
        .draw(fromCenter: NSPoint(x: body.midX, y: body.maxY), radius: 0,
              toCenter: NSPoint(x: body.midX, y: body.maxY), radius: body.width * 0.75, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Heart (56% of the body's width) and the port bar beneath it, centred as one group.
    let hw = body.width * 0.56
    let hh = hw * 0.90
    let visible = hh * 0.94 // the curves top out a little below the box
    let gap = body.width * 0.055
    let barW = body.width * 0.20, barH = max(1, body.width * 0.045)
    let group = visible + gap + barH
    let groupBottom = body.midY - group / 2 + body.width * 0.01 // a hair above centre, optically
    let barRect = NSRect(x: body.midX - barW / 2, y: groupBottom, width: barW, height: barH)
    let heartRect = NSRect(x: body.midX - hw / 2, y: groupBottom + barH + gap, width: hw, height: hh)
    let h = heart(in: heartRect)

    // Soft shadow under both shapes.
    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = srgb(0.45, 0.02, 0.08, 0.30)
    lift.shadowOffset = NSSize(width: 0, height: -8 * u)
    lift.shadowBlurRadius = 18 * u
    lift.set()
    NSColor.white.setFill()
    h.fill()
    NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Heart face: white to a whisper of pink, then an inner shadow along its upper edge.
    NSGradient(starting: NSColor.white, ending: srgb(1.0, 0.93, 0.94))!.draw(in: h, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    h.addClip()
    let ring = NSBezierPath(rect: heartRect.insetBy(dx: -hw, dy: -hw))
    ring.append(h)
    ring.windingRule = .evenOdd
    let inner = NSShadow()
    inner.shadowColor = srgb(0.70, 0.10, 0.18, 0.30)
    inner.shadowOffset = NSSize(width: 0, height: -6 * u)
    inner.shadowBlurRadius = 14 * u
    inner.set()
    NSColor.black.setFill()
    ring.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(out.path)
