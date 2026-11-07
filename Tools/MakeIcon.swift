// Draws Muty's app icon and writes it as an .icns file.
// Usage: MakeIcon <output.icns>
import AppKit

let outFile = URL(fileURLWithPath: CommandLine.arguments[1])

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // macOS icon grid: 824/1024 body with rounded corners.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.99, green: 0.42, blue: 0.36, alpha: 1),
                        NSColor(calibratedRed: 0.86, green: 0.16, blue: 0.32, alpha: 1)])!
        .draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2, width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// ICNS = "icns" + total length, then one chunk per size: 4-char type + length + PNG data.
let chunks: [(String, Int)] = [
    ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
    ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
]

func bigEndian(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
}

var body = Data()
for (type, size) in chunks {
    let png = render(size)
    body += type.data(using: .ascii)! + bigEndian(png.count + 8) + png
}
let icns = "icns".data(using: .ascii)! + bigEndian(body.count + 8) + body
try icns.write(to: outFile)
