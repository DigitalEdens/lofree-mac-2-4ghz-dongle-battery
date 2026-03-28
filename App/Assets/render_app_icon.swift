import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: render_app_icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let iconSpecs: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let cornerRatio: CGFloat = 0.22

func color(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xff) / 255.0
    let g = CGFloat((hex >> 8) & 0xff) / 255.0
    let b = CGFloat(hex & 0xff) / 255.0
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func pngData(from image: NSImage) -> Data? {
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff)
    else {
        return nil
    }
    return rep.representation(using: .png, properties: [:])
}

func roundedRectPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawKeyboard(in rect: NSRect, scale: CGFloat) {
    let platePath = roundedRectPath(rect, radius: rect.height * 0.16)
    color(0xF8FAFC, alpha: 0.92).setFill()
    platePath.fill()

    color(0x0F172A, alpha: 0.18).setStroke()
    platePath.lineWidth = max(1.0, 1.5 * scale)
    platePath.stroke()

    let topInset = rect.height * 0.20
    let sideInset = rect.width * 0.10
    let keyArea = rect.insetBy(dx: sideInset, dy: topInset)
    let columns = 7
    let rows = 3
    let gap = max(1.0, rect.width * 0.03)
    let keyWidth = (keyArea.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
    let keyHeight = (keyArea.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

    for row in 0..<rows {
        for column in 0..<columns {
            let keyRect = NSRect(
                x: keyArea.minX + CGFloat(column) * (keyWidth + gap),
                y: keyArea.maxY - CGFloat(row + 1) * keyHeight - CGFloat(row) * gap,
                width: keyWidth,
                height: keyHeight
            )
            let keyPath = roundedRectPath(keyRect, radius: keyHeight * 0.28)
            color(0xCBD5E1, alpha: row == 2 && column >= 2 && column <= 4 ? 0.95 : 0.82).setFill()
            keyPath.fill()
        }
    }
}

func drawBatteryBadge(in rect: NSRect, scale: CGFloat) {
    let bodyPath = roundedRectPath(rect, radius: rect.height * 0.42)
    color(0xF8FAFC, alpha: 0.96).setFill()
    bodyPath.fill()

    let terminalWidth = rect.width * 0.10
    let terminalRect = NSRect(
        x: rect.maxX,
        y: rect.midY - rect.height * 0.18,
        width: terminalWidth,
        height: rect.height * 0.36
    )
    let terminalPath = roundedRectPath(terminalRect, radius: terminalRect.height * 0.35)
    color(0xF8FAFC, alpha: 0.96).setFill()
    terminalPath.fill()

    let fillInset = rect.height * 0.12
    let fillRect = rect.insetBy(dx: fillInset, dy: fillInset)
    let visibleWidth = fillRect.width * 0.76
    let levelRect = NSRect(x: fillRect.minX, y: fillRect.minY, width: visibleWidth, height: fillRect.height)
    let levelPath = roundedRectPath(levelRect, radius: fillRect.height * 0.32)
    color(0x22C55E, alpha: 1.0).setFill()
    levelPath.fill()

    let stroke = roundedRectPath(rect, radius: rect.height * 0.42)
    color(0x0F172A, alpha: 0.10).setStroke()
    stroke.lineWidth = max(1.0, 1.2 * scale)
    stroke.stroke()
}

for spec in iconSpecs {
    let size = spec.size
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * cornerRatio

    let backgroundPath = roundedRectPath(canvas, radius: radius)
    let gradient = NSGradient(colors: [
        color(0x0F172A),
        color(0x0F766E),
        color(0x14B8A6)
    ])!
    gradient.draw(in: backgroundPath, angle: 52)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x020617, alpha: 0.32)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.set()
    backgroundPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let highlight = roundedRectPath(
        NSRect(x: size * 0.08, y: size * 0.54, width: size * 0.72, height: size * 0.24),
        radius: size * 0.10
    )
    color(0xFFFFFF, alpha: 0.16).setFill()
    highlight.fill()

    let keyboardRect = NSRect(
        x: size * 0.15,
        y: size * 0.18,
        width: size * 0.58,
        height: size * 0.38
    )
    drawKeyboard(in: keyboardRect, scale: size / 128.0)

    let badgeRect = NSRect(
        x: size * 0.60,
        y: size * 0.58,
        width: size * 0.22,
        height: size * 0.12
    )
    drawBatteryBadge(in: badgeRect, scale: size / 128.0)

    image.unlockFocus()

    guard let png = pngData(from: image) else {
        fputs("failed to encode \(spec.name)\n", stderr)
        exit(1)
    }

    try png.write(to: outputDir.appendingPathComponent(spec.name))
}
