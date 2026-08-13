// Draws the app icon into an .iconset directory for iconutil.
//
// Generated rather than checked in as binary blobs: it is one small file to
// review instead of ten PNGs nobody can diff.
//
//   swift Tools/make-icon.swift build/Flasher.iconset

import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.iconset>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true
)

func render(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let side = CGFloat(size)
    // macOS icons sit inside their canvas rather than filling it.
    let inset = side * 0.055
    let plate = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let squircle = NSBezierPath(
        roundedRect: plate, xRadius: side * 0.225, yRadius: side * 0.225
    )
    NSGradient(
        colors: [
            NSColor(srgbRed: 0.29, green: 0.53, blue: 0.97, alpha: 1),
            NSColor(srgbRed: 0.09, green: 0.24, blue: 0.62, alpha: 1),
        ]
    )?.draw(in: squircle, angle: -90)

    if let symbol = NSImage(
        systemSymbolName: "bolt.horizontal.fill", accessibilityDescription: nil
    )?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: side * 0.44, weight: .semibold)
    ) {
        // Symbols come out black; repaint white by filling through the alpha.
        let glyph = NSImage(size: symbol.size)
        glyph.lockFocus()
        let bounds = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: bounds)
        NSColor.white.set()
        bounds.fill(using: .sourceAtop)
        glyph.unlockFocus()

        glyph.draw(in: NSRect(
            x: (side - glyph.size.width) / 2,
            y: (side - glyph.size.height) / 2,
            width: glyph.size.width,
            height: glyph.size.height
        ))
    }

    return rep.representation(using: .png, properties: [:])
}

// The names iconutil expects; each size is needed at 1x and 2x.
for (size, name) in [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
] {
    guard let png = render(size: size) else { continue }
    try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
}
