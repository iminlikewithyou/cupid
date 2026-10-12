import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The icon of a Windows executable, read from its PE resources (RT_GROUP_ICON names the
/// images; each is an RT_ICON: PNG for 256x256 entries, a headerless DIB for smaller ones).
/// Pure parsing; the chosen image is wrapped as a one-image .ico so ImageIO decodes either kind.
public enum PEIcon {
    static let rtIcon: UInt32 = 3
    static let rtGroupIcon: UInt32 = 14

    public struct Entry: Sendable, Equatable {
        /// 256 for a stored 0.
        public let width: Int, height: Int
        public let bitCount: Int
        public let id: UInt16
        let colorCount: UInt8, planes: UInt16
    }

    struct Reader {
        let d: [UInt8]
        func u16(_ o: Int) -> UInt16? { o >= 0 && o + 2 <= d.count ? UInt16(d[o]) | UInt16(d[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> UInt32? {
            o >= 0 && o + 4 <= d.count ? UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 : nil
        }
    }

    /// The resource section of a PE file: its file offset and the RVA it maps to.
    struct Resources {
        let r: Reader
        /// File offset of the resource directory root.
        let root: Int
        /// RVA -> file offset for the section holding the resources.
        let rvaBase: Int, fileBase: Int

        init?(_ d: [UInt8]) {
            let r = Reader(d: d)
            guard d.count > 0x40, d[0] == 0x4d, d[1] == 0x5a, let pe = r.u32(0x3c).map(Int.init),
                  r.u32(pe) == 0x0000_4550, let sections = r.u16(pe + 6), let optionalSize = r.u16(pe + 20),
                  let magic = r.u16(pe + 24) else { return nil }
            let optional = pe + 24
            let directories = optional + (magic == 0x20b ? 112 : 96)
            guard let rva = r.u32(directories + 2 * 8).map(Int.init), rva > 0 else { return nil }
            let table = optional + Int(optionalSize)
            for i in 0..<Int(sections) {
                let s = table + 40 * i
                guard let vsize = r.u32(s + 8), let va = r.u32(s + 12), let rawSize = r.u32(s + 16),
                      let raw = r.u32(s + 20) else { return nil }
                let start = Int(va), size = Int(max(vsize, rawSize))
                if rva >= start && rva < start + size {
                    self.r = r
                    rvaBase = start
                    fileBase = Int(raw)
                    root = Int(raw) + (rva - start)
                    return
                }
            }
            return nil
        }

        func offset(rva: Int) -> Int { fileBase + (rva - rvaBase) }

        /// (id or nil for a named entry, offset field) of each entry of the directory at `dir`.
        func entries(_ dir: Int) -> [(id: UInt32?, target: UInt32)] {
            guard let named = r.u16(dir + 12), let ids = r.u16(dir + 14) else { return [] }
            return (0..<Int(named) + Int(ids)).compactMap { i in
                let e = dir + 16 + 8 * i
                guard let name = r.u32(e), let target = r.u32(e + 4) else { return nil }
                return (name & 0x8000_0000 != 0 ? nil : name, target)
            }
        }

        func subdirectory(_ target: UInt32) -> Int? {
            target & 0x8000_0000 != 0 ? root + Int(target & 0x7fff_ffff) : nil
        }

        /// The data of the first language of resource (`type`, `id`), or of every `type` entry
        /// when `id` is nil (in directory order).
        func data(type: UInt32, id: UInt32?) -> [(id: UInt32?, bytes: ArraySlice<UInt8>)] {
            guard let typeDir = entries(root).first(where: { $0.id == type }).flatMap({ subdirectory($0.target) }) else { return [] }
            var out: [(UInt32?, ArraySlice<UInt8>)] = []
            for entry in entries(typeDir) where id == nil || entry.id == id {
                guard let langDir = subdirectory(entry.target), let leaf = entries(langDir).first,
                      leaf.target & 0x8000_0000 == 0 else { continue }
                let dataEntry = root + Int(leaf.target)
                guard let rva = r.u32(dataEntry), let size = r.u32(dataEntry + 4) else { continue }
                let start = offset(rva: Int(rva)), end = start + Int(size)
                guard start >= 0, end <= r.d.count, start < end else { continue }
                out.append((entry.id, r.d[start..<end]))
            }
            return out
        }
    }

    /// The entries of the first icon group.
    static func group(_ bytes: ArraySlice<UInt8>) -> [Entry] {
        let r = Reader(d: Array(bytes))
        guard r.u16(0) == 0, r.u16(2) == 1, let count = r.u16(4) else { return [] }
        return (0..<Int(count)).compactMap { i in
            let e = 6 + 14 * i
            guard e + 14 <= r.d.count, let planes = r.u16(e + 4), let bits = r.u16(e + 6), let id = r.u16(e + 12) else { return nil }
            return Entry(width: r.d[e] == 0 ? 256 : Int(r.d[e]), height: r.d[e + 1] == 0 ? 256 : Int(r.d[e + 1]),
                         bitCount: Int(bits), id: id, colorCount: r.d[e + 2], planes: planes)
        }
    }

    /// The largest image of the executable's first icon group (deepest colour on a tie), as a
    /// one-image .ico file. Nil when the file has no icon resources.
    public static func largestIcon(exe data: [UInt8]) -> Data? {
        guard let res = Resources(data), let first = res.data(type: rtGroupIcon, id: nil).first else { return nil }
        let entries = group(first.bytes).sorted { ($0.width * $0.height, $0.bitCount) > ($1.width * $1.height, $1.bitCount) }
        for entry in entries {
            guard let image = res.data(type: rtIcon, id: UInt32(entry.id)).first?.bytes, !image.isEmpty else { continue }
            var ico: [UInt8] = [0, 0, 1, 0, 1, 0]
            func le16(_ v: UInt16) { ico += [UInt8(v & 0xff), UInt8(v >> 8)] }
            func le32(_ v: UInt32) { ico += (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
            ico += [UInt8(entry.width & 0xff), UInt8(entry.height & 0xff), entry.colorCount, 0]
            le16(entry.planes); le16(UInt16(entry.bitCount)); le32(UInt32(image.count)); le32(22)
            ico += image
            return Data(ico)
        }
        return nil
    }

    /// The largest icon of the executable at `url`, decoded.
    public static func largestImage(exe url: URL) -> CGImage? {
        guard let bytes = try? Data(contentsOf: url), let ico = largestIcon(exe: [UInt8](bytes)),
              let source = CGImageSourceCreateWithData(ico as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 1, image.height > 1 else { return nil }
        return image
    }
}

/// Mac app icons drawn from another image.
public enum MacIcon {
    /// `image` on Apple's macOS icon grid, as App/Resources/make-icon.swift draws Heartport's:
    /// an 824/1024 rounded square (corner radius 185.4/1024) centred with ~10% margins, filled
    /// with the image (aspect fill) and a soft drop shadow, at `pixels` square.
    public static func render(_ image: CGImage, pixels: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let u = CGFloat(pixels) / 1024
        let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
        let square = CGPath(roundedRect: body, cornerWidth: 185.4 * u, cornerHeight: 185.4 * u, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 20 * u, color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(square)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(square)
        ctx.clip()
        let scale = max(body.width / CGFloat(image.width), body.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h))
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Writes an .icns of `image` drawn on the icon grid (every iconset size), via iconutil.
    public static func writeICNS(_ image: CGImage, to icns: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("heartport-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = work.appendingPathComponent("icon.iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                guard let drawn = render(image, pixels: size * scale) else {
                    throw HeartportError(.io, "Could not draw the \(size)@\(scale)x icon")
                }
                try writePNG(drawn, to: iconset.appendingPathComponent(name))
            }
        }
        let out = try ProcessRunner.capture("/usr/bin/iconutil", ["-c", "icns", "-o", icns.path, iconset.path])
        guard out.status == 0 else { throw HeartportError(.process, "iconutil failed: \(out.stderr)") }
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw HeartportError(.io, "Could not create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw HeartportError(.io, "Could not write \(url.lastPathComponent)") }
    }
}
