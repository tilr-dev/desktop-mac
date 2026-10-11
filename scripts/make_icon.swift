// Render the existing Tilr landing favicon (Resources/AppIcon.svg) into a macOS iconset.
// Source: ~/design/landings/tilr/index.html. Keep the geometry/colors in sync with the SVG.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // A transparent margin keeps the icon aligned with other Dock icons.
        let unit = CGFloat(pixels) * 0.875 / 32
        context.translateBy(x: CGFloat(pixels) * 0.0625, y: CGFloat(pixels) * 0.9375)
        context.scaleBy(x: unit, y: -unit)
        context.setFillColor(CGColor(red: 0x81 / 255.0, green: 0xce / 255.0, blue: 0x99 / 255.0, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 32, height: 32), cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()
        let glyph = CGMutablePath()
        glyph.move(to: CGPoint(x: 10, y: 26))
        glyph.addLine(to: CGPoint(x: 10, y: 9))
        glyph.addLine(to: CGPoint(x: 15, y: 9))
        glyph.addLine(to: CGPoint(x: 15, y: 12))
        glyph.addCurve(to: CGPoint(x: 21.5, y: 8.6), control1: CGPoint(x: 16, y: 9.7), control2: CGPoint(x: 18, y: 8.6))
        glyph.addLine(to: CGPoint(x: 21.5, y: 14))
        glyph.addCurve(to: CGPoint(x: 15.5, y: 18.5), control1: CGPoint(x: 17.5, y: 14), control2: CGPoint(x: 15.5, y: 15.2))
        glyph.addLine(to: CGPoint(x: 15.5, y: 26))
        glyph.closeSubpath()
        context.setFillColor(CGColor(red: 0x0f / 255.0, green: 0x13 / 255.0, blue: 0x17 / 255.0, alpha: 1))
        context.addPath(glyph)
        context.fillPath()
        let image = NSBitmapImageRep(cgImage: context.makeImage()!)
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}

// ICNS permits PNG payloads; package every standard and Retina representation directly.
func uint32(_ value: Int) -> Data {
    var bigEndian = UInt32(value).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
var chunks = Data()
for (kind, name) in [
    ("icp4", "16x16"), ("icp5", "32x32"), ("ic07", "128x128"),
    ("ic08", "256x256"), ("ic09", "512x512"), ("ic10", "512x512@2x"),
    ("ic11", "16x16@2x"), ("ic12", "32x32@2x"),
    ("ic13", "128x128@2x"), ("ic14", "256x256@2x"),
] {
    let png = try Data(contentsOf: output.appendingPathComponent("icon_\(name).png"))
    chunks.append(Data(kind.utf8))
    chunks.append(uint32(png.count + 8))
    chunks.append(png)
}
var icns = Data("icns".utf8)
icns.append(uint32(chunks.count + 8))
icns.append(chunks)
try icns.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
