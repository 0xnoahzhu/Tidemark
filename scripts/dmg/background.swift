// Draws the background of the DMG's installer window: a light gray canvas with a dashed arrow pointing from the
// app (left) to the Applications link (right), at 1x and 2x, combined into one HiDPI TIFF.
//
// Usage: swift scripts/dmg/background.swift scripts/dmg/background.tiff
// The window is 540 x 380 pt (scripts/dmg/settings.py); the icons sit at x 130 and 410, y 220.
import AppKit

let size = CGSize(width: 540, height: 380)
let canvas = NSColor(srgbRed: 237 / 255, green: 236 / 255, blue: 236 / 255, alpha: 1)
let stroke = NSColor(srgbRed: 96 / 255, green: 96 / 255, blue: 96 / 255, alpha: 1)

/// The arrow's outline in points, y growing downwards: a shaft, then a head reaching to the tip.
let arrow: [CGPoint] = [
    CGPoint(x: 243, y: 212), CGPoint(x: 262.5, y: 212), CGPoint(x: 262.5, y: 193.5), CGPoint(x: 292, y: 223.25),
    CGPoint(x: 262.5, y: 253), CGPoint(x: 262.5, y: 234.5), CGPoint(x: 243, y: 234.5),
]

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    canvas.setFill()
    CGRect(origin: .zero, size: size).fill()

    let path = NSBezierPath()
    path.move(to: CGPoint(x: arrow[0].x, y: size.height - arrow[0].y))
    for point in arrow.dropFirst() { path.line(to: CGPoint(x: point.x, y: size.height - point.y)) }
    path.close()
    path.lineWidth = 1.5
    path.lineJoinStyle = .bevel
    path.setLineDash([4, 2], count: 2, phase: 0)
    stroke.setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "background.tiff")
let temporary = FileManager.default.temporaryDirectory.appending(path: "tidemark-dmg-\(UUID().uuidString)", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let low = temporary.appending(path: "background.png"), high = temporary.appending(path: "background@2x.png")
try render(scale: 1).write(to: low)
try render(scale: 2).write(to: high)

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", low.path, high.path, "-out", output.path]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { exit(tiffutil.terminationStatus) }
print("wrote \(output.path)")
