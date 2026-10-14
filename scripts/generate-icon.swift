import AppKit

// Original vector mark, rendered at each native macOS icon size.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 205, yRadius: 205)
    NSColor(srgbRed: 0.075, green: 0.095, blue: 0.105, alpha: 1).setFill()
    background.fill()
    NSColor(srgbRed: 0.74, green: 0.96, blue: 0.79, alpha: 0.09).setStroke()
    background.lineWidth = 3; background.stroke()
    for index in 0..<3 {
        let left = CGFloat(277 + index * 72)
        let lower = CGFloat(270 - index * 28)
        let door = NSBezierPath()
        door.move(to: NSPoint(x: left, y: lower))
        door.line(to: NSPoint(x: left, y: lower + 463))
        door.curve(to: NSPoint(x: left + 36, y: lower + 499), controlPoint1: NSPoint(x: left, y: lower + 486), controlPoint2: NSPoint(x: left + 13, y: lower + 499))
        door.line(to: NSPoint(x: left + 256, y: lower + 499))
        door.line(to: NSPoint(x: left + 256, y: lower + 17))
        NSColor(srgbRed: 0.74, green: 0.96, blue: 0.79, alpha: Double(index + 1) / 3).setStroke()
        door.lineWidth = 30; door.lineCapStyle = .round; door.lineJoinStyle = .round; door.stroke()
    }
    let leaf = NSBezierPath()
    leaf.move(to: NSPoint(x: 451, y: 214)); leaf.line(to: NSPoint(x: 451, y: 656))
    leaf.line(to: NSPoint(x: 628, y: 596)); leaf.line(to: NSPoint(x: 628, y: 169)); leaf.close()
    NSColor(srgbRed: 0.74, green: 0.96, blue: 0.79, alpha: 1).setFill(); leaf.fill()
    NSColor(srgbRed: 0.09, green: 0.13, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 573, y: 379, width: 19, height: 29)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to: destination.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to: destination.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
}
