// Draws the Switchcraft app icon and menu-bar glyph.
//
//   xcrun swiftc -O Scripts/make-icon.swift -o build/make-icon && build/make-icon Resources
//
// Writes Resources/AppIcon.icns (via iconutil), Resources/MenuBarIcon.png and MenuBarIcon@2x.png.

import AppKit
import CoreGraphics

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// Four-point sparkle with concave sides.
func sparkle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath(), k = r * 0.16
    p.move(to: CGPoint(x: cx, y: cy - r))
    p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + k, y: cy - k))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx + k, y: cy + k))
    p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - k, y: cy + k))
    p.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx - k, y: cy - k))
    p.closeSubpath()
    return p
}

func cross(_ cx: CGFloat, _ cy: CGFloat, length: CGFloat, thickness: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addRoundedRect(in: CGRect(x: cx - thickness / 2, y: cy - length / 2, width: thickness, height: length), cornerWidth: radius, cornerHeight: radius)
    p.addRoundedRect(in: CGRect(x: cx - length / 2, y: cy - thickness / 2, width: length, height: thickness), cornerWidth: radius, cornerHeight: radius)
    return p
}

func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let n = points.count
    p.move(to: CGPoint(x: (points[n - 1].x + points[0].x) / 2, y: (points[n - 1].y + points[0].y) / 2))
    for i in 0..<n { p.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius) }
    p.closeSubpath()
    return p
}

func context(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, 1024-unit design space.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    return ctx
}

func drawIcon(_ ctx: CGContext) {
    // Squircle body on the macOS icon grid (824 pt inside 1024), with a soft drop shadow.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(body); ctx.setFillColor(color(0x34197A)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x6D44D6), color(0x40209A), color(0x1F0E47)]),
                           start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)]), startCenter: CGPoint(x: 340, y: 230), startRadius: 0,
                           endCenter: CGPoint(x: 340, y: 230), endRadius: 520, options: [])

    // Gold contact pins.
    ctx.setFillColor(color(0xE2B04F))
    for x: CGFloat in [430, 578] { ctx.fill(CGRect(x: x, y: 694, width: 16, height: 72)) }

    // Bottom housing, lip, top housing.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x0B0420, 0.55))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 300, y: 562, width: 424, height: 136), cornerWidth: 30, cornerHeight: 30, transform: nil))
    ctx.setFillColor(color(0x221539)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 284, y: 542, width: 456, height: 36), cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.setFillColor(color(0x5A43A0)); ctx.fillPath()
    let top = roundedPolygon([CGPoint(x: 322, y: 550), CGPoint(x: 702, y: 550), CGPoint(x: 652, y: 412), CGPoint(x: 372, y: 412)], radius: 26)
    ctx.saveGState()
    ctx.addPath(top); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xE4D8FF), color(0xA98CF2)]), start: CGPoint(x: 512, y: 412), end: CGPoint(x: 512, y: 550), options: [])
    ctx.restoreGState()

    // Stem: a red Cherry-style stem rising out of the housing (the switch's side profile), lit from the left.
    let stem = CGPath(roundedRect: CGRect(x: 462, y: 246, width: 100, height: 184), cornerWidth: 10, cornerHeight: 10, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 14, color: color(0x1A0B45, 0.55))
    ctx.addPath(stem); ctx.setFillColor(color(0xD9443B)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(stem); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xF36A5A), color(0xD9443B), color(0xA92C28)]), start: CGPoint(x: 462, y: 0), end: CGPoint(x: 562, y: 0), options: [])
    // Shoulder where the stem's cross arms meet: a slightly darker band, the detail that says "MX stem".
    ctx.setFillColor(color(0x000000, 0.14)); ctx.fill(CGRect(x: 462, y: 300, width: 100, height: 14))
    ctx.setFillColor(color(0xFFFFFF, 0.28)); ctx.fill(CGRect(x: 472, y: 252, width: 10, height: 170))
    ctx.restoreGState()

    // One soft sparkle, plus a small accent: the craft, not the headline.
    for (x, y, r, alpha) in [(CGFloat(724), CGFloat(282), CGFloat(62), CGFloat(0.95)), (CGFloat(800), CGFloat(372), CGFloat(20), CGFloat(0.75))] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: r * 0.35, color: color(0xFFD27A, 0.45))
        ctx.setAlpha(alpha)
        ctx.addPath(sparkle(x, y, r)); ctx.clip()
        ctx.drawLinearGradient(gradient([color(0xFFF3C4), color(0xF0C35E)]), start: CGPoint(x: x, y: y - r), end: CGPoint(x: x, y: y + r), options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

/// Template glyph for the menu bar: stem column, housing and pins (a switch in profile) and a
/// small sparkle; black on transparent.
func drawGlyph(_ ctx: CGContext) {
    ctx.setFillColor(color(0x000000))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 395, y: 120, width: 130, height: 270), cornerWidth: 34, cornerHeight: 34, transform: nil)); ctx.fillPath()
    ctx.addPath(roundedPolygon([CGPoint(x: 190, y: 590), CGPoint(x: 730, y: 590), CGPoint(x: 650, y: 425), CGPoint(x: 270, y: 425)], radius: 34)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 130, y: 630, width: 660, height: 180), cornerWidth: 48, cornerHeight: 48, transform: nil)); ctx.fillPath()
    for x: CGFloat in [300, 580] { ctx.fill(CGRect(x: x, y: 800, width: 48, height: 110)) }
    ctx.addPath(sparkle(840, 230, 125)); ctx.fillPath()
}

func png(_ ctx: CGContext, to url: URL) throws {
    guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let ctx = context(points * scale)
    ctx.interpolationQuality = .high
    drawIcon(ctx)
    try png(ctx, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
let preview = context(1024)
drawIcon(preview)
try png(preview, to: out.appendingPathComponent("AppIcon-1024.png"))
for (name, size) in [("MenuBarIcon.png", 18), ("MenuBarIcon@2x.png", 36)] {
    let ctx = context(size)
    drawGlyph(ctx)
    try png(ctx, to: out.appendingPathComponent(name))
}
print("Wrote AppIcon.icns, AppIcon-1024.png, MenuBarIcon.png, MenuBarIcon@2x.png to \(out.path)")
