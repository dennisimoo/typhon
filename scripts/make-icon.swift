// Renders Typhon's app icon into the asset catalog. Usage: swift scripts/make-icon.swift
import AppKit

let out = URL(filePath: "Typhon/Resources/Assets.xcassets/AppIcon.appiconset")

func render(_ size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        let inset = 100 * s
        let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSGraphicsContext.current?.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 0.10, green: 0.16, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.13, green: 0.40, blue: 0.85, alpha: 1),
            NSColor(srgbRed: 0.38, green: 0.68, blue: 1.0, alpha: 1),
        ])!.draw(in: rect, angle: 70)
        // Glassy top sheen.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()

        let config = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let glyph = NSImage(systemSymbolName: "tornado", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let g = glyph.size
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(srgbRed: 0.05, green: 0.1, blue: 0.35, alpha: 0.45)
            shadow.shadowBlurRadius = 18 * s
            shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
            shadow.set()
            glyph.draw(in: NSRect(x: (size - g.width) / 2, y: (size - g.height) / 2 - 6 * s, width: g.width, height: g.height))
        }
        NSColor.white.withAlphaComponent(0.25).setStroke()
        shape.lineWidth = 3 * s
        shape.stroke()
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(CGFloat(base * scale)).write(to: out.appending(path: name))
        images.append(#"{ "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(base)x\#(base)", "filename" : "\#(name)" }"#)
    }
}
try! #"{ "images" : [ \#(images.joined(separator: ",\n")) ], "info" : { "author" : "xcode", "version" : 1 } }"#
    .write(to: out.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
try! render(1024).write(to: URL(filePath: "docs/images/icon.png"))
print("icon written")
