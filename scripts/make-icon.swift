import AppKit
import Foundation

guard CommandLine.arguments.count == 2 || (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--foreground") else {
    fatalError("Usage: swift scripts/make-icon.swift /path/to/iNotes.iconset [--foreground]")
}
let foregroundOnly = CommandLine.arguments.count == 3
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

// Original vector artwork: one faceted pencil on a quiet, luminous macOS tile.
// ICNS preserves the existing macOS 14+ fallback. No fonts or bitmap inputs.
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func polygon(_ points: [NSPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    guard let first = points.first else { return path }
    path.move(to: first)
    for point in points.dropFirst() { path.line(to: point) }
    path.close()
    return path
}

func drawIcon(pixels: Int, foregroundOnly: Bool = false) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)

    if !foregroundOnly {
    let tile = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 196, yRadius: 196)
    NSGradient(colorsAndLocations:
        (color(0.77, 0.85, 0.89), 0),
        (color(0.91, 0.95, 0.97), 0.48),
        (color(0.99, 1.00, 1.00), 1))!.draw(in: tile, angle: 85)
    context.saveGState()
    tile.addClip()
    let rim = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192)
    color(1, 1, 1, 0.75).setStroke()
    rim.lineWidth = 4
    rim.stroke()
    context.restoreGState()
    }

    context.saveGState()
    context.translateBy(x: 512, y: 512)
    context.rotate(by: .pi / 4)

    let silhouette = NSBezierPath()
    silhouette.move(to: NSPoint(x: -405, y: 0))
    silhouette.line(to: NSPoint(x: -270, y: -72))
    silhouette.line(to: NSPoint(x: 320, y: -72))
    silhouette.curve(to: NSPoint(x: 360, y: -32), controlPoint1: NSPoint(x: 342, y: -72), controlPoint2: NSPoint(x: 360, y: -54))
    silhouette.line(to: NSPoint(x: 360, y: 32))
    silhouette.curve(to: NSPoint(x: 320, y: 72), controlPoint1: NSPoint(x: 360, y: 54), controlPoint2: NSPoint(x: 342, y: 72))
    silhouette.line(to: NSPoint(x: -270, y: 72))
    silhouette.close()

    context.saveGState()
    if !foregroundOnly {
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 19, color: color(0.08, 0.18, 0.24, 0.24).cgColor)
    }
    color(0.16, 0.33, 0.41).setFill()
    silhouette.fill()
    context.restoreGState()

    context.saveGState()
    silhouette.addClip()
    // Broad lacquer faces remain distinct when the icon is tiny.
    color(0.12, 0.29, 0.38).setFill()
    NSBezierPath(rect: NSRect(x: -270, y: -72, width: 520, height: 48)).fill()
    NSGradient(starting: color(0.18, 0.40, 0.48), ending: color(0.31, 0.58, 0.64))!
        .draw(in: NSRect(x: -270, y: -24, width: 520, height: 56), angle: 90)
    color(0.44, 0.67, 0.72).setFill()
    NSBezierPath(rect: NSRect(x: -270, y: 32, width: 520, height: 40)).fill()
    color(1, 1, 1, 0.25).setFill()
    NSBezierPath(rect: NSRect(x: -270, y: 62, width: 505, height: 3)).fill()

    // A small silver ferrule and pale cap keep the pencil generic.
    NSGradient(colorsAndLocations:
        (color(0.50, 0.61, 0.66), 0), (color(0.94, 0.98, 0.99), 0.65),
        (color(0.71, 0.81, 0.85), 1))!.draw(in: NSRect(x: 235, y: -72, width: 39, height: 144), angle: 90)
    NSGradient(starting: color(0.67, 0.77, 0.81), ending: color(0.94, 0.98, 0.99))!
        .draw(in: NSRect(x: 274, y: -72, width: 86, height: 144), angle: 90)
    color(0.35, 0.48, 0.54, 0.30).setFill()
    NSBezierPath(rect: NSRect(x: 269, y: -72, width: 3, height: 144)).fill()

    let wood = polygon([NSPoint(x: -405, y: 0), NSPoint(x: -270, y: -72), NSPoint(x: -270, y: 72)])
    NSGradient(starting: color(0.75, 0.60, 0.40), ending: color(0.95, 0.84, 0.64))!.draw(in: wood, angle: 90)
    let graphite = polygon([NSPoint(x: -405, y: 0), NSPoint(x: -350, y: -29.3), NSPoint(x: -350, y: 29.3)])
    NSGradient(starting: color(0.10, 0.15, 0.19), ending: color(0.24, 0.32, 0.37))!.draw(in: graphite, angle: 90)

    context.restoreGState()
    context.restoreGState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let file = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try drawIcon(pixels: size * scale, foregroundOnly: foregroundOnly).write(to: file, options: .atomic)
    }
}
