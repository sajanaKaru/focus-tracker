#!/usr/bin/env swift
// Draws the app icon and writes scripts/AppIcon.icns. Usage: swift scripts/make-icon.swift [output.icns]
import AppKit

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixels) / 1024
    let art = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = NSBezierPath(roundedRect: art, xRadius: 185 * s, yRadius: 185 * s)
    let indigo = color(0x6366F1)
    let violet = color(0x8B5CF6)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 14 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    indigo.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [indigo, violet])!.draw(in: tile, angle: -45)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let top = NSRect(x: art.minX, y: art.midY, width: art.width, height: art.height / 2)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!.draw(in: top, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let center = 512 * s
    func ring(radius: CGFloat, width: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath(ovalIn: NSRect(x: center - radius * s, y: center - radius * s, width: radius * 2 * s, height: radius * 2 * s))
        path.lineWidth = width * s
        NSColor.white.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }
    ring(radius: 245, width: 46, alpha: 1)
    ring(radius: 145, width: 34, alpha: 0.9)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center - 56 * s, y: center - 56 * s, width: 112 * s, height: 112 * s)).fill()

    return rep.representation(using: .png, properties: [:])!
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/AppIcon.icns"
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try render(pixels: pixels).write(to: iconset.appendingPathComponent("\(name).png"))
}

let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", output]
try tool.run()
tool.waitUntilExit()
guard tool.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output)")
