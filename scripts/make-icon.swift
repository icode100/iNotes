import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift scripts/make-icon.swift /path/to/iNotes.iconset")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    let body = NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 192, yRadius: 192)
    NSColor(calibratedRed: 0.19, green: 0.24, blue: 0.53, alpha: 1).setFill()
    body.fill()
    let paper = NSBezierPath(roundedRect: NSRect(x: 248, y: 196, width: 535, height: 649), xRadius: 42, yRadius: 42)
    NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.92, alpha: 1).setFill()
    paper.fill()
    let spine = NSBezierPath(roundedRect: NSRect(x: 220, y: 196, width: 84, height: 649), xRadius: 26, yRadius: 26)
    NSColor(calibratedRed: 0.53, green: 0.63, blue: 0.92, alpha: 1).setFill()
    spine.fill()
    NSColor(calibratedRed: 0.75, green: 0.77, blue: 0.83, alpha: 1).setStroke()
    for y in stride(from: 380, through: 650, by: 90) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 366, y: y))
        line.line(to: NSPoint(x: 689, y: y))
        line.lineWidth = 15
        line.lineCapStyle = .round
        line.stroke()
    }
    let nib = NSBezierPath()
    nib.move(to: NSPoint(x: 569, y: 243))
    nib.line(to: NSPoint(x: 729, y: 403))
    nib.line(to: NSPoint(x: 797, y: 335))
    nib.line(to: NSPoint(x: 637, y: 175))
    nib.line(to: NSPoint(x: 547, y: 153))
    nib.close()
    NSColor(calibratedRed: 0.90, green: 0.58, blue: 0.26, alpha: 1).setFill()
    nib.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let file = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try drawIcon(pixels: size * scale).write(to: file, options: .atomic)
    }
}
