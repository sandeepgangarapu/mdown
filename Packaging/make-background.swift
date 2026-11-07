import AppKit

// Draws the DMG window background at 1x and 2x: a slate gradient (mid-tone, so Finder's labels
// stay legible in both Light and Dark Mode), an arrow from the app to Applications, and a caption.
// Usage: swift Packaging/make-background.swift Packaging
let size = NSSize(width: 640, height: 400)
let appCenter = NSPoint(x: 160, y: 400 - 205)
let appsCenter = NSPoint(x: 480, y: 400 - 205)

func render(scale: CGFloat, to path: String) {
    let pixels = NSSize(width: size.width * scale, height: size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.510, green: 0.553, blue: 0.612, alpha: 1),
        NSColor(srgbRed: 0.420, green: 0.463, blue: 0.525, alpha: 1)
    ])!
    gradient.draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Soft spotlight behind the icons.
    let glow = NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])!
    glow.draw(fromCenter: NSPoint(x: 320, y: 200), radius: 0, toCenter: NSPoint(x: 320, y: 200), radius: 300, options: [])

    // Arrow
    let arrow = NSBezierPath()
    let startX = appCenter.x + 92, endX = appsCenter.x - 92, y = appCenter.y + 6
    arrow.move(to: NSPoint(x: startX, y: y))
    arrow.line(to: NSPoint(x: endX, y: y))
    arrow.move(to: NSPoint(x: endX - 16, y: y + 16))
    arrow.line(to: NSPoint(x: endX, y: y))
    arrow.line(to: NSPoint(x: endX - 16, y: y - 16))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(white: 1, alpha: 0.92).setStroke()
    arrow.stroke()

    // Caption
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let title = NSAttributedString(string: "Drag MDown to Applications to install it", attributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ])
    title.draw(in: NSRect(x: 0, y: 400 - 78, width: 640, height: 26))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
render(scale: 1, to: out + "/background.png")
render(scale: 2, to: out + "/background@2x.png")
print("ok")
