// Renders the Lily app icon straight into an .icns.
// Usage: swift scripts/make-icon.swift <out.icns>
// One image per pixel size: iconutil would also store "128@2x" and "256@2x", byte-for-byte
// copies of the 256 and 512 px images (about 220 KB); macOS picks an icon image by pixel size.
// Follows the macOS icon grid: an 824pt rounded square centered on a 1024pt canvas.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.icns>\n".utf8))
    exit(64)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile, as on system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.36, green: 0.30, blue: 0.96, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.93, green: 0.33, blue: 0.62, alpha: 1).cgColor,
                  NSColor(srgbRed: 1.00, green: 0.62, blue: 0.36, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

    // The mark: a bold rainbow arc over a short baseline.
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(96)
    ctx.addArc(center: CGPoint(x: 512, y: 440), radius: 230, startAngle: .pi * 0.08, endAngle: .pi * 0.92, clockwise: false)
    ctx.strokePath()
    ctx.setLineWidth(72)
    ctx.move(to: CGPoint(x: 400, y: 330))
    ctx.addLine(to: CGPoint(x: 624, y: 330))
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// icns: "icns", total length, then (type, length including its 8-byte header, PNG) chunks, all
// lengths big-endian.
func bigEndian(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
let chunks: [(type: String, pixels: Int)] = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
                                             ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)]
var body = Data()
for chunk in chunks {
    let png = render(pixels: chunk.pixels)
    body += Data(chunk.type.utf8) + bigEndian(png.count + 8) + png
}
try (Data("icns".utf8) + bigEndian(body.count + 8) + body).write(to: out)
