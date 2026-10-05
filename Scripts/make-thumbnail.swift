// Erzeugt Resources/thumbnail.png und thumbnail@2x.png für die Bildschirmschoner-Liste.
// Aufruf: swift Scripts/make-thumbnail.swift
import AppKit

func render(width: Int, height: Int, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: width, height: height)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.30, alpha: 1),
        NSColor(calibratedRed: 0.35, green: 0.18, blue: 0.55, alpha: 1),
        NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.35, alpha: 1),
    ])!.draw(in: rect, angle: 30)

    // Filmstreifen oben und unten
    let strip = CGFloat(height) * 0.14
    NSColor(white: 0, alpha: 0.45).setFill()
    NSRect(x: 0, y: 0, width: CGFloat(width), height: strip).fill()
    NSRect(x: 0, y: CGFloat(height) - strip, width: CGFloat(width), height: strip).fill()
    NSColor(white: 1, alpha: 0.55).setFill()
    let hole = strip * 0.45
    var x = hole
    while x < CGFloat(width) - hole {
        for y in [(strip - hole) / 2, CGFloat(height) - strip + (strip - hole) / 2] {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: hole * 1.3, height: hole), xRadius: hole * 0.2, yRadius: hole * 0.2).fill()
        }
        x += hole * 2.6
    }

    // Play-Symbol in der Mitte
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(height) * 0.38, weight: .regular)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 0.35, green: 0.18, blue: 0.55, alpha: 1), .white]))
    if let symbol = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2,
                               width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources").path
render(width: 90, height: 58, to: "\(dir)/thumbnail.png")
render(width: 180, height: 116, to: "\(dir)/thumbnail@2x.png")
print("Vorschaubilder geschrieben nach \(dir)")
