// Renders Resources/AppIcon.icns: a usage gauge on a warm squircle.
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle background (macOS icon grid: 824/1024 content box).
    let inset = s * 100 / 1024
    let box = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    // Meter Coral, top-lit: #F29A72 → #E76F51 → #D95E43.
    NSGradient(colors: [NSColor(red: 0xF2 / 255.0, green: 0x9A / 255.0, blue: 0x72 / 255.0, alpha: 1),
                        NSColor(red: 0xE7 / 255.0, green: 0x6F / 255.0, blue: 0x51 / 255.0, alpha: 1),
                        NSColor(red: 0xD9 / 255.0, green: 0x5E / 255.0, blue: 0x43 / 255.0, alpha: 1)])!.draw(in: bg, angle: -90)

    // Gauge: 270° track + 62% progress arc.
    let center = NSPoint(x: box.midX, y: box.midY - box.height * 0.02)
    let radius = box.width * 0.30
    let width = box.width * 0.085
    let start: CGFloat = 225, sweep: CGFloat = 270

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
    track.lineWidth = width; track.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.28).setStroke(); track.stroke()

    let progress = NSBezierPath()
    progress.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - sweep * 0.62, clockwise: true)
    progress.lineWidth = width; progress.lineCapStyle = .round
    NSColor.white.setStroke(); progress.stroke()

    // Needle.
    let angle = (start - sweep * 0.62) * .pi / 180
    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: NSPoint(x: center.x + cos(angle) * radius * 0.72, y: center.y + sin(angle) * radius * 0.72))
    needle.lineWidth = width * 0.55; needle.lineCapStyle = .round
    NSColor.white.setStroke(); needle.stroke()
    let hub = width * 0.75
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run(); task.waitUntilExit()
try render(1024).write(to: root.appendingPathComponent("docs/icon.png"))
print(task.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
