import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func draw(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Unable to create icon context") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 210, yRadius: 210)
    let gradient = NSGradient(starting: NSColor(red: 0.08, green: 0.28, blue: 0.30, alpha: 1), ending: NSColor(red: 0.07, green: 0.12, blue: 0.19, alpha: 1))!
    gradient.draw(in: tile, angle: 270)
    let base = NSBezierPath()
    base.appendArc(withCenter: NSPoint(x: 512, y: 465), radius: 265, startAngle: 210, endAngle: -30, clockwise: true)
    base.lineWidth = 54; base.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.13).setStroke(); base.stroke()
    let active = NSBezierPath()
    active.appendArc(withCenter: NSPoint(x: 512, y: 465), radius: 265, startAngle: 210, endAngle: 47, clockwise: true)
    active.lineWidth = 54; active.lineCapStyle = .round
    NSColor(red: 0.28, green: 0.86, blue: 0.71, alpha: 1).setStroke(); active.stroke()
    let needle = NSBezierPath()
    needle.move(to: NSPoint(x: 512, y: 465)); needle.line(to: NSPoint(x: 620, y: 604))
    needle.lineWidth = 34; needle.lineCapStyle = .round
    NSColor.white.setStroke(); needle.stroke()
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 479, y: 432, width: 66, height: 66)).fill()
    let dot = NSBezierPath(roundedRect: NSRect(x: 366, y: 266, width: 292, height: 28), xRadius: 14, yRadius: 14)
    NSColor.white.withAlphaComponent(0.42).setFill(); dot.fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to render icon") }
    return data
}
for base in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        try draw(size: base * multiplier).write(to: directory.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
