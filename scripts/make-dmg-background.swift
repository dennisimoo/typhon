// Renders the DMG window background (660×400 @2x). Usage: swift scripts/make-dmg-background.swift
import AppKit

let size = NSSize(width: 660, height: 400)
let scale: CGFloat = 2
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(origin: .zero, size: size)

NSGradient(colors: [
    NSColor(srgbRed: 0.96, green: 0.97, blue: 1.0, alpha: 1),
    NSColor(srgbRed: 0.88, green: 0.92, blue: 0.99, alpha: 1),
])!.draw(in: rect, angle: -90)

// A soft arrow from the app to Applications.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 262, y: 200))
arrow.curve(to: NSPoint(x: 398, y: 200), controlPoint1: NSPoint(x: 300, y: 228), controlPoint2: NSPoint(x: 360, y: 228))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
NSColor(srgbRed: 0.16, green: 0.45, blue: 0.95, alpha: 0.55).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 386, y: 212))
head.line(to: NSPoint(x: 399, y: 200))
head.line(to: NSPoint(x: 383, y: 194))
head.lineWidth = 3
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
    ]
    NSAttributedString(string: text, attributes: attributes).draw(in: NSRect(x: 0, y: y, width: 660, height: 40))
}
draw("Drag Typhon into Applications", size: 17, weight: .semibold, color: NSColor(white: 0.15, alpha: 1), y: 318)
draw("Then open it from Applications (first time: right-click → Open).", size: 12, weight: .regular,
     color: NSColor(white: 0.4, alpha: 1), y: 60)
NSGraphicsContext.restoreGraphicsState()

try! FileManager.default.createDirectory(atPath: "scripts/dmg", withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: "scripts/dmg/background.png"))
print("scripts/dmg/background.png")
