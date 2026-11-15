// Creates an original, Retina-sized app icon without external assets.
import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
    bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func color(_ hex: UInt32, alpha: Double = 1) -> NSColor {
    NSColor(srgbRed: Double(hex >> 16) / 255, green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255, alpha: alpha)
}

func rounded(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ radius: Double) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                 xRadius: radius, yRadius: radius)
}

func stroke(_ points: [(Double, Double)], _ hex: UInt32, width: Double, alpha: Double = 1) {
    let shape = NSBezierPath()
    if let start = points.first { shape.move(to: NSPoint(x: start.0, y: start.1)) }
    for point in points.dropFirst() { shape.line(to: NSPoint(x: point.0, y: point.1)) }
    shape.lineWidth = width
    shape.lineCapStyle = .round
    shape.lineJoinStyle = .round
    color(hex, alpha: alpha).setStroke()
    shape.stroke()
}

let tile = rounded(68, 68, 888, 888, 194)
NSGradient(starting: color(0x101F36), ending: color(0x1B4154))!.draw(in: tile, angle: 90)
tile.lineWidth = 5
color(0x78BDCC, alpha: 0.34).setStroke()
tile.stroke()
let border = rounded(101, 101, 822, 822, 165)
border.lineWidth = 3
color(0xA9F3EA, alpha: 0.1).setStroke()
border.stroke()

NSGraphicsContext.saveGraphicsState()
tile.addClip()
for coordinate in stride(from: 137.0, through: 900.0, by: 72.0) {
    stroke([(coordinate, 125), (coordinate, 900)], 0x8CD4D6, width: 1, alpha: 0.10)
    stroke([(125, coordinate), (900, coordinate)], 0x8CD4D6, width: 1, alpha: 0.10)
}
NSGraphicsContext.restoreGraphicsState()

let shadow = rounded(307, 241, 393, 515, 58)
color(0x081727, alpha: 0.78).setFill()
shadow.fill()
let paper = NSBezierPath()
paper.move(to: NSPoint(x: 352, y: 274))
paper.line(to: NSPoint(x: 640, y: 274))
paper.curve(to: NSPoint(x: 690, y: 324), controlPoint1: NSPoint(x: 670, y: 274),
            controlPoint2: NSPoint(x: 690, y: 294))
paper.line(to: NSPoint(x: 690, y: 647))
paper.line(to: NSPoint(x: 562, y: 781))
paper.line(to: NSPoint(x: 352, y: 781))
paper.curve(to: NSPoint(x: 302, y: 731), controlPoint1: NSPoint(x: 322, y: 781),
            controlPoint2: NSPoint(x: 302, y: 761))
paper.line(to: NSPoint(x: 302, y: 324))
paper.curve(to: NSPoint(x: 352, y: 274), controlPoint1: NSPoint(x: 302, y: 294),
            controlPoint2: NSPoint(x: 322, y: 274))
paper.close()
NSGradient(starting: color(0x8CDCD5), ending: color(0xE3FFFC))!.draw(in: paper, angle: 90)
stroke([(562, 765), (562, 647), (674, 647)], 0x3C9296, width: 12)
stroke([(374, 580), (489, 580)], 0x265665, width: 25)
stroke([(374, 514), (605, 514)], 0x32747D, width: 18)
stroke([(374, 454), (550, 454)], 0x32747D, width: 18)
stroke([(374, 394), (473, 394)], 0x32747D, width: 18)

let badge = rounded(527, 225, 243, 243, 69)
color(0x142B40).setFill()
badge.fill()
badge.lineWidth = 7
color(0x84E9DA).setStroke()
badge.stroke()
stroke([(577, 349), (625, 301), (718, 403)], 0x96F4DF, width: 25)

NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
