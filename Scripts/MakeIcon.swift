import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)

        let tile = NSBezierPath(roundedRect: NSRect(x: 45, y: 45, width: 422, height: 422), xRadius: 98, yRadius: 98)
        let navy = NSColor(srgbRed: 0.12, green: 0.19, blue: 0.48, alpha: 1)
        let blue = NSColor(srgbRed: 0.31, green: 0.43, blue: 0.90, alpha: 1)
        NSGradient(starting: blue, ending: navy)!.draw(in: tile, angle: -62)

        let display = NSBezierPath(roundedRect: NSRect(x: 122, y: 154, width: 268, height: 205), xRadius: 32, yRadius: 32)
        NSColor.white.withAlphaComponent(0.13).setFill()
        display.fill()
        NSColor.white.withAlphaComponent(0.88).setStroke()
        display.lineWidth = 11
        display.stroke()

        let bar = NSBezierPath(roundedRect: NSRect(x: 150, y: 310, width: 212, height: 24), xRadius: 12, yRadius: 12)
        NSColor(srgbRed: 0.68, green: 0.85, blue: 1, alpha: 1).setFill()
        bar.fill()
        let notch = NSBezierPath(roundedRect: NSRect(x: 221, y: 310, width: 70, height: 24), xRadius: 10, yRadius: 10)
        navy.setFill()
        notch.fill()

        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
