// Renders the WindowSnapper app icon.
//   swift scripts/make_icon.swift <output.iconset>
//   iconutil -c icns <output.iconset> -o Resources/AppIcon.icns
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon into a 1024×1024 coordinate space (origin bottom-left).
func drawIcon() {
    // Body: the standard macOS icon squircle (824pt on a 1024 canvas) with a soft shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x3B3FD8).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x5B8CFF), color(0x4A4DE6), color(0x2E1F9E)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: bodyPath, angle: -90)

    // A faint top highlight for depth.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The "screen": a translucent panel holding the snapped tiles.
    let screen = NSRect(x: 214, y: 254, width: 596, height: 516)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 56, yRadius: 56)
    NSColor.white.withAlphaComponent(0.14).setFill()
    screenPath.fill()
    NSColor.white.withAlphaComponent(0.35).setStroke()
    screenPath.lineWidth = 6
    screenPath.stroke()

    // Tiles: left half, bottom-right quarter, and the highlighted top-right corner.
    let inset: CGFloat = 30, gap: CGFloat = 22, r: CGFloat = 30
    let inner = screen.insetBy(dx: inset, dy: inset)
    let halfW = (inner.width - gap) / 2
    let halfH = (inner.height - gap) / 2
    let left = NSRect(x: inner.minX, y: inner.minY, width: halfW, height: inner.height)
    let topRight = NSRect(x: inner.minX + halfW + gap, y: inner.minY + halfH + gap, width: halfW, height: halfH)
    let bottomRight = NSRect(x: inner.minX + halfW + gap, y: inner.minY, width: halfW, height: halfH)

    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: left, xRadius: r, yRadius: r).fill()
    NSColor.white.withAlphaComponent(0.45).setFill()
    NSBezierPath(roundedRect: bottomRight, xRadius: r, yRadius: r).fill()

    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0xFFB13B, 0.8)
    glow.shadowBlurRadius = 30
    glow.set()
    let tr = NSBezierPath(roundedRect: topRight, xRadius: r, yRadius: r)
    NSGradient(colors: [color(0xFFD36E), color(0xFF9F2E)])!.draw(in: tr, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Little "window bar" dots on the left tile so it reads as a window.
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        color(UInt32(c)).setFill()
        NSBezierPath(ovalIn: NSRect(x: left.minX + 30 + CGFloat(i) * 38, y: left.maxY - 56, width: 24, height: 24)).fill()
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(out.path)")
