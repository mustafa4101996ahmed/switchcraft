// Draws the DMG window background (660 × 400 pt, @1x and @2x). Content stays above y = 340:
// Finder may draw a path bar over the bottom of the window.
//   xcrun swiftc -O Scripts/make-dmg-background.swift -o build/make-dmg-background && build/make-dmg-background build/dmg

import AppKit

let size = CGSize(width: 660, height: 400)
/// Icon centres, in Finder's top-left coordinates; must match Scripts/dmg-settings.py.
let appCenter = CGPoint(x: 170, y: 160)
let applicationsCenter = CGPoint(x: 490, y: 160)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Flip to top-left origin so coordinates match Finder's.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)

    let colors = [NSColor(srgbRed: 0.975, green: 0.965, blue: 1.0, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.925, green: 0.905, blue: 0.985, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil)!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // Arrow from the app to Applications.
    let purple = NSColor(srgbRed: 0.42, green: 0.27, blue: 0.84, alpha: 0.55).cgColor
    ctx.setStrokeColor(purple)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    let start = CGPoint(x: appCenter.x + 82, y: appCenter.y), end = CGPoint(x: applicationsCenter.x - 82, y: applicationsCenter.y)
    ctx.move(to: start)
    ctx.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: appCenter.y - 34))
    ctx.strokePath()
    ctx.setFillColor(purple)
    ctx.move(to: CGPoint(x: end.x + 6, y: end.y + 2))
    ctx.addLine(to: CGPoint(x: end.x - 14, y: end.y - 12))
    ctx.addLine(to: CGPoint(x: end.x - 11, y: end.y + 13))
    ctx.closePath()
    ctx.fillPath()

    // Text is drawn unflipped by AppKit, so restore the original orientation for it.
    ctx.saveGState()
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 0, y: -size.height)
    func centered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        attributed.draw(in: CGRect(x: 40, y: size.height - y - 40, width: size.width - 80, height: 40))
    }
    centered("Drag Switchcraft to Applications", y: 268, font: .systemFont(ofSize: 15, weight: .semibold),
             color: NSColor(srgbRed: 0.16, green: 0.12, blue: 0.27, alpha: 1))
    centered("First open: if macOS says it can't check the app, open System Settings › Privacy & Security",
             y: 298, font: .systemFont(ofSize: 11.5), color: NSColor(srgbRed: 0.33, green: 0.3, blue: 0.42, alpha: 1))
    centered("and click Open Anyway. You only do this once.", y: 315, font: .systemFont(ofSize: 11.5),
             color: NSColor(srgbRed: 0.33, green: 0.3, blue: 0.42, alpha: 1))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/dmg")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "background.png"), (2, "background@2x.png")] {
    try render(scale: scale).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("Wrote \(out.path)/background.png and background@2x.png")
