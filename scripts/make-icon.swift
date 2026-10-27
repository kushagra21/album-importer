// Draws Album Importer's app icon from geometric primitives (no fonts, symbols or
// images) and writes assets/AppIcon.icns plus assets/icon-256.png.
//
// Usage: swift scripts/make-icon.swift   (from the repository root)

import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
/// Apple's macOS icon grid: an 824 pt rounded square centred on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileCorner: CGFloat = 185

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Warm sunset: amber to deep rose.
let backgroundTop = rgb(0xF59E0B)
let backgroundBottom = rgb(0xBE185D)

/// A photo print: white card with a sky, a sun and two hills, rotated about its centre.
func drawPhoto(_ ctx: CGContext, centre c: CGPoint, size: CGSize, angle: CGFloat, dim: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: angle)
    let card = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 26, color: rgb(0x000000, 0.28))
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, dim ? 0.85 : 1))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let inset: CGFloat = 30
    let photo = card.insetBy(dx: inset, dy: inset).offsetBy(dx: 0, dy: -14)
    let picture = CGRect(x: photo.minX, y: photo.minY, width: photo.width, height: photo.height - 28)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: picture, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.clip()
    let sky = CGGradient(colorsSpace: nil, colors: [rgb(0x38BDF8), rgb(0xBAE6FD)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: picture.minY), end: CGPoint(x: 0, y: picture.maxY), options: [])
    if !dim {
        ctx.setFillColor(rgb(0xFDE047))
        let r = picture.width * 0.11
        ctx.fillEllipse(in: CGRect(x: picture.maxX - picture.width * 0.3 - r, y: picture.minY + picture.height * 0.22 - r, width: 2 * r, height: 2 * r))
    }
    let back = CGMutablePath()
    back.move(to: CGPoint(x: picture.minX, y: picture.maxY))
    back.addLine(to: CGPoint(x: picture.minX + picture.width * 0.38, y: picture.minY + picture.height * 0.42))
    back.addLine(to: CGPoint(x: picture.minX + picture.width * 0.75, y: picture.maxY))
    back.closeSubpath()
    ctx.addPath(back)
    ctx.setFillColor(rgb(0x15803D))
    ctx.fillPath()
    let front = CGMutablePath()
    front.move(to: CGPoint(x: picture.minX + picture.width * 0.35, y: picture.maxY))
    front.addLine(to: CGPoint(x: picture.minX + picture.width * 0.68, y: picture.minY + picture.height * 0.55))
    front.addLine(to: CGPoint(x: picture.maxX + 20, y: picture.maxY))
    front.closeSubpath()
    ctx.addPath(front)
    ctx.setFillColor(rgb(0x22C55E))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext) {
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tileCorner, cornerHeight: tileCorner, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0x000000, 0.3))
    ctx.addPath(tilePath)
    ctx.setFillColor(backgroundBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: nil, colors: [backgroundTop, backgroundBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: tile.midX, y: tile.minY), end: CGPoint(x: tile.midX, y: tile.maxY), options: [])

    // A stack of prints.
    let size = CGSize(width: 430, height: 360)
    drawPhoto(ctx, centre: CGPoint(x: 470, y: 420), size: size, angle: -0.16, dim: true)
    drawPhoto(ctx, centre: CGPoint(x: 540, y: 450), size: size, angle: 0.07, dim: false)

    // A timeline: a bar with dated stops, the last one filled.
    let y: CGFloat = 770
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.9))
    ctx.setLineWidth(16)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 250, y: y))
    ctx.addLine(to: CGPoint(x: 774, y: y))
    ctx.strokePath()
    for (i, x) in [250.0, 425.0, 600.0, 774.0].enumerated() {
        let r: CGFloat = i == 3 ? 40 : 28
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        if i < 3 {
            ctx.setFillColor(backgroundBottom)
            ctx.fillEllipse(in: CGRect(x: x - 12, y: y - 12, width: 24, height: 24))
        }
    }
    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / canvas
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)  // draw in a 1024 top-left canvas at any size
    drawIcon(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let assets = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "assets")
let iconset = FileManager.default.temporaryDirectory.appending(path: "AlbumImporter.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
try png(pixels: 256).write(to: assets.appending(path: "icon-256.png"))

let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appending(path: "AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote assets/AppIcon.icns and assets/icon-256.png")
