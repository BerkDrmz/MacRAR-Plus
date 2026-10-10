import AppKit

// Original MacRAR Plus artwork. All contours are drawn here, without stock symbols.
let out = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func gradient(_ path: NSBezierPath, _ colors: [NSColor], angle: CGFloat = -75) {
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
func folio(dx: CGFloat = 0, dy: CGFloat = 0) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 300, y: 250))
    path.curve(to: NSPoint(x: 244, y: 306), controlPoint1: NSPoint(x: 267, y: 250), controlPoint2: NSPoint(x: 244, y: 273))
    path.line(to: NSPoint(x: 244, y: 696))
    path.curve(to: NSPoint(x: 298, y: 750), controlPoint1: NSPoint(x: 244, y: 730), controlPoint2: NSPoint(x: 264, y: 750))
    path.line(to: NSPoint(x: 402, y: 750))
    path.curve(to: NSPoint(x: 439, y: 731), controlPoint1: NSPoint(x: 420, y: 750), controlPoint2: NSPoint(x: 428, y: 744))
    path.line(to: NSPoint(x: 470, y: 695))
    path.line(to: NSPoint(x: 712, y: 695))
    path.curve(to: NSPoint(x: 772, y: 635), controlPoint1: NSPoint(x: 750, y: 695), controlPoint2: NSPoint(x: 772, y: 673))
    path.line(to: NSPoint(x: 772, y: 306))
    path.curve(to: NSPoint(x: 716, y: 250), controlPoint1: NSPoint(x: 772, y: 273), controlPoint2: NSPoint(x: 749, y: 250))
    path.close()
    path.transform(using: AffineTransform(translationByX: dx, byY: dy))
    return path
}

let tile = rounded(NSRect(x: 100, y: 100, width: 824, height: 824), 182)
NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = color(0x001A1E, 0.28)
tileShadow.shadowBlurRadius = 24
tileShadow.shadowOffset = NSSize(width: 0, height: -12)
tileShadow.set()
color(0x163B40).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
gradient(tile, [color(0x315E62), color(0x173D42), color(0x09262C)])
color(0xC3F1E9, 0.18).setStroke()
tile.lineWidth = 2
tile.stroke()

// Offset leaves make the archive read as a collection even at Dock size.
NSGraphicsContext.saveGraphicsState()
let folioShadow = NSShadow()
folioShadow.shadowColor = color(0x001316, 0.55)
folioShadow.shadowBlurRadius = 38
folioShadow.shadowOffset = NSSize(width: 0, height: -22)
folioShadow.set()
gradient(folio(dx: -23, dy: 52), [color(0xF7E7D0), color(0xBCAF96)])
NSGraphicsContext.restoreGraphicsState()
gradient(folio(dx: -10, dy: 27), [color(0xD4E1D8), color(0x829E97)])
color(0xF6FFF4, 0.65).setStroke()
let leaf = folio(dx: -10, dy: 27)
leaf.lineWidth = 3
leaf.stroke()

let front = folio()
NSGraphicsContext.saveGraphicsState()
folioShadow.set()
gradient(front, [color(0xFFD292), color(0xEEA462), color(0xBC653D)])
NSGraphicsContext.restoreGraphicsState()
color(0xFFE5B5, 0.7).setStroke()
front.lineWidth = 3
front.stroke()

// Two softly bevelled panels embrace the zipper spine.
NSGraphicsContext.saveGraphicsState()
front.addClip()
gradient(rounded(NSRect(x: 270, y: 276, width: 252, height: 445), 30),
         [color(0xFFE3AE, 0.32), color(0xD67B45, 0.05)])
gradient(rounded(NSRect(x: 560, y: 276, width: 185, height: 392), 30),
         [color(0xFFE4BA, 0.16), color(0x8B3F29, 0.16)])
let spine = rounded(NSRect(x: 521, y: 250, width: 44, height: 445), 8)
gradient(spine, [color(0x88492F), color(0x633B2A)])
color(0xFFDC9D, 0.5).setStroke()
spine.lineWidth = 3
spine.stroke()

// Interlocking teeth are intentionally broad enough to survive small sizes.
for index in 0..<17 {
    let y = CGFloat(283 + index * 20)
    gradient(rounded(NSRect(x: 515, y: y, width: 25, height: 12), 4),
             [color(0xFFF0CB), color(0xC99354)])
    gradient(rounded(NSRect(x: 546, y: y + 8, width: 25, height: 12), 4),
             [color(0xFFF0CB), color(0xC99354)])
}
NSGraphicsContext.restoreGraphicsState()

// The slider cutout forms a subtle plus, part of the object rather than a badge.
let slider = rounded(NSRect(x: 509, y: 595, width: 68, height: 84), 22)
NSGraphicsContext.saveGraphicsState()
let metalShadow = NSShadow()
metalShadow.shadowColor = color(0x4D261A, 0.42)
metalShadow.shadowBlurRadius = 10
metalShadow.shadowOffset = NSSize(width: 0, height: -7)
metalShadow.set()
gradient(slider, [color(0xFFF3DA), color(0xD5AD70)])
NSGraphicsContext.restoreGraphicsState()
let pull = rounded(NSRect(x: 519, y: 623, width: 48, height: 94), 18)
gradient(pull, [color(0xFFF4D9), color(0xE6C590), color(0xB78B50)])
color(0xFFF7E7, 0.8).setStroke()
pull.lineWidth = 2
pull.stroke()
let plus = NSBezierPath()
plus.move(to: NSPoint(x: 532, y: 688)); plus.line(to: NSPoint(x: 554, y: 688))
plus.move(to: NSPoint(x: 543, y: 677)); plus.line(to: NSPoint(x: 543, y: 699))
plus.lineWidth = 7
plus.lineCapStyle = .round
color(0x714D31).setStroke()
plus.stroke()

NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
