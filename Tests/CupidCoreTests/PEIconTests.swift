import CoreGraphics
import ImageIO
import XCTest
@testable import CupidCore

/// A minimal PE32+ file whose .rsrc section holds `resources` (type, id, bytes).
func makePE(resources: [(type: UInt32, id: UInt32, data: [UInt8])]) -> [UInt8] {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
    func dirHeader(ids: Int) -> [UInt8] { [UInt8](repeating: 0, count: 12) + le16(0) + le16(ids) }

    let sectionRVA = 0x1000, sectionFile = 0x200
    let types = Array(Set(resources.map(\.type))).sorted()
    // Layout: root, one directory per type, one language directory per resource, data entries, data.
    var offset = 16 + 8 * types.count
    var typeDir: [UInt32: Int] = [:]
    for t in types { typeDir[t] = offset; offset += 16 + 8 * resources.filter { $0.type == t }.count }
    var langDir: [Int] = []
    for _ in resources { langDir.append(offset); offset += 16 + 8 }
    var dataEntry: [Int] = []
    for _ in resources { dataEntry.append(offset); offset += 16 }
    var dataAt: [Int] = []
    for r in resources { dataAt.append(offset); offset += (r.data.count + 7) & ~7 }

    var rsrc = [UInt8](repeating: 0, count: offset)
    func put(_ bytes: [UInt8], at o: Int) { rsrc.replaceSubrange(o..<o + bytes.count, with: bytes) }
    put(dirHeader(ids: types.count), at: 0)
    for (i, t) in types.enumerated() { put(le32(Int(t)) + le32(0x8000_0000 | typeDir[t]!), at: 16 + 8 * i) }
    for t in types {
        let members = resources.indices.filter { resources[$0].type == t }
        put(dirHeader(ids: members.count), at: typeDir[t]!)
        for (k, i) in members.enumerated() {
            put(le32(Int(resources[i].id)) + le32(0x8000_0000 | langDir[i]), at: typeDir[t]! + 16 + 8 * k)
        }
    }
    for i in resources.indices {
        put(dirHeader(ids: 1) + le32(1033) + le32(dataEntry[i]), at: langDir[i])
        put(le32(sectionRVA + dataAt[i]) + le32(resources[i].data.count) + le32(0) + le32(0), at: dataEntry[i])
        put(resources[i].data, at: dataAt[i])
    }

    var pe = [UInt8](repeating: 0, count: sectionFile)
    pe[0] = 0x4d; pe[1] = 0x5a
    pe.replaceSubrange(0x3c..<0x40, with: le32(0x40))
    let coff = 0x40
    pe.replaceSubrange(coff..<coff + 4, with: [0x50, 0x45, 0, 0])
    pe.replaceSubrange(coff + 4..<coff + 6, with: le16(0x8664))
    pe.replaceSubrange(coff + 6..<coff + 8, with: le16(1))
    pe.replaceSubrange(coff + 20..<coff + 22, with: le16(240))
    let optional = coff + 24
    pe.replaceSubrange(optional..<optional + 2, with: le16(0x20b))
    pe.replaceSubrange(optional + 108..<optional + 112, with: le32(16))
    let resourceDir = optional + 112 + 16
    pe.replaceSubrange(resourceDir..<resourceDir + 8, with: le32(sectionRVA) + le32(rsrc.count))
    let section = optional + 240
    pe.replaceSubrange(section..<section + 5, with: Array(".rsrc".utf8))
    pe.replaceSubrange(section + 8..<section + 24, with: le32(rsrc.count) + le32(sectionRVA) + le32(rsrc.count) + le32(sectionFile))
    return pe + rsrc
}

/// GRPICONDIR with (width, height, bitCount, size, id) entries; 256 is stored as 0.
func makeGroup(_ entries: [(Int, Int, Int, Int, Int)]) -> [UInt8] {
    var out: [UInt8] = [0, 0, 1, 0, UInt8(entries.count), 0]
    for (w, h, bits, size, id) in entries {
        out += [UInt8(w & 0xff), UInt8(h & 0xff), 0, 0, 1, 0, UInt8(bits), 0]
        out += (0..<4).map { UInt8((size >> (8 * $0)) & 0xff) }
        out += [UInt8(id & 0xff), UInt8(id >> 8)]
    }
    return out
}

/// A 32-bit DIB icon image (BITMAPINFOHEADER, BGRA rows bottom-up, then the AND mask).
func makeDIB(size: Int, bgra: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
    func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
    var out = le32(40) + le32(size) + le32(size * 2) + [1, 0, 32, 0] + le32(0) + le32(0) + le32(0) + le32(0) + le32(0) + le32(0)
    for _ in 0..<(size * size) { out += [bgra.0, bgra.1, bgra.2, bgra.3] }
    let maskRow = ((size + 31) / 32) * 4
    out += [UInt8](repeating: 0, count: maskRow * size)
    return out
}

func makePNG(size: Int, red: CGFloat) throws -> [UInt8] {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pe-icon-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try MacIcon.writePNG(ctx.makeImage()!, to: url)
    return [UInt8](try Data(contentsOf: url))
}

final class PEIconTests: XCTestCase {
    func decode(_ ico: Data?) -> CGImage? {
        guard let ico, let source = CGImageSourceCreateWithData(ico as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func testPicksTheLargestImageWhichIsPNG() throws {
        let png = try makePNG(size: 256, red: 1)
        let dib = makeDIB(size: 16, bgra: (255, 0, 0, 255))
        let pe = makePE(resources: [
            (3, 1, dib), (3, 2, png),
            (14, 101, makeGroup([(16, 16, 32, dib.count, 1), (256, 256, 32, png.count, 2)])),
        ])
        let image = try XCTUnwrap(decode(PEIcon.largestIcon(exe: pe)))
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
    }

    func testDecodesADIBIcon() throws {
        let dib = makeDIB(size: 32, bgra: (0, 0, 255, 255)) // red
        let pe = makePE(resources: [(3, 7, dib), (14, 1, makeGroup([(32, 32, 32, dib.count, 7)]))])
        let ico = try XCTUnwrap(PEIcon.largestIcon(exe: pe))
        let image = try XCTUnwrap(decode(ico))
        XCTAssertEqual(image.width, 32)
        // The pixel is red.
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(px[0], 200)
        XCTAssertLessThan(px[1], 40)
        XCTAssertLessThan(px[2], 40)
    }

    func testNoIconResources() {
        XCTAssertNil(PEIcon.largestIcon(exe: makePE(resources: [(16, 1, [1, 2, 3, 4])])))
        XCTAssertNil(PEIcon.largestIcon(exe: [0x4d, 0x5a]))
        XCTAssertNil(PEIcon.largestIcon(exe: []))
    }

    func testWritesAnICNSOnTheIconGrid() throws {
        let png = try makePNG(size: 256, red: 1)
        let pe = makePE(resources: [(3, 1, png), (14, 1, makeGroup([(256, 256, 32, png.count, 1)]))])
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent("game.exe")
        try Data(pe).write(to: exe)
        let image = try XCTUnwrap(PEIcon.largestImage(exe: exe))
        let drawn = try XCTUnwrap(MacIcon.render(image, pixels: 1024))
        // Corners are transparent (margins); the centre is the icon.
        let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(drawn, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(px[3], 0, "corner pixel is transparent")
        let centre = (512 * 1024 + 512) * 4
        XCTAssertEqual(px[centre + 3], 255)
        XCTAssertGreaterThan(px[centre], 200)
        let icns = root.appendingPathComponent("x.icns")
        try MacIcon.writeICNS(image, to: icns)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(icns as CFURL, nil))
        XCTAssertGreaterThanOrEqual(CGImageSourceGetCount(source), 5)
    }

    /// The installed game's exe, when there is one on this machine (read only).
    func testInstalledGameExe() throws {
        let exe = Paths(dataRoot: Paths.defaultDataRoot()).gameExe
        guard FileManager.default.fileExists(atPath: exe.path) else { throw XCTSkip("Heartopia is not installed here") }
        let image = try XCTUnwrap(PEIcon.largestImage(exe: exe))
        XCTAssertGreaterThanOrEqual(image.width, 32)
        print("xdt.exe icon: \(image.width)x\(image.height)")
    }
}
