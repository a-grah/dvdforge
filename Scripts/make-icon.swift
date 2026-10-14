// Renders the dvdForge app icon: an iridescent DVD resting on an anvil, glowing
// where they meet. Writes a 1024 px master PNG; Scripts/make-icon.sh turns it
// into the AppIcon asset catalog.
//
// usage: swift Scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics
import Foundation

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work top-down like a design tool.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                            CGFloat(hex & 0xff) / 255, a])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

// MARK: Background squircle (macOS icon grid: 824 pt body, 100 pt margin)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0x14172E))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
ctx.drawLinearGradient(gradient([(0, rgb(0x2A2F5A)), (0.55, rgb(0x161937)), (1, rgb(0x0B0C1D))]),
                       start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// Warm forge light rising from below.
ctx.drawRadialGradient(gradient([(0, rgb(0xFF7A1A, 0.55)), (0.45, rgb(0xFF4D00, 0.18)), (1, rgb(0xFF4D00, 0))]),
                       startCenter: CGPoint(x: 512, y: 700), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 700), endRadius: 430, options: [])
ctx.restoreGState()

// MARK: Disc

let center = CGPoint(x: 512, y: 430)
let outer = 268.0, hub = 92.0, hole = 38.0

func ring(_ r1: CGFloat, _ r2: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addEllipse(in: CGRect(x: center.x - r1, y: center.y - r1, width: 2 * r1, height: 2 * r1))
    p.addEllipse(in: CGRect(x: center.x - r2, y: center.y - r2, width: 2 * r2, height: 2 * r2))
    return p
}

// Drop shadow under the disc.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: rgb(0x000000, 0.55))
ctx.addPath(ring(outer, hole))
ctx.setFillColor(rgb(0xB8BCC8))
ctx.fillPath(using: .evenOdd)
ctx.restoreGState()

// Data surface: silver base with an iridescent sweep (a conic gradient built from slices).
ctx.saveGState()
ctx.addPath(ring(outer, hub))
ctx.clip(using: .evenOdd)
ctx.drawRadialGradient(gradient([(0, rgb(0xEEF0F6)), (1, rgb(0xA9AEBD))]),
                       startCenter: center, startRadius: hub, endCenter: center, endRadius: outer, options: [])
let slices = 360
for i in 0 ..< slices {
    let a0 = Double(i) / Double(slices) * 2 * .pi
    let a1 = Double(i + 1) / Double(slices) * 2 * .pi + 0.01
    // Two rainbow bands around the disc, strongest at the diagonals, like real light on a DVD.
    let hue = (Double(i) / Double(slices) * 2).truncatingRemainder(dividingBy: 1)
    let strength = 0.16 + 0.30 * pow(abs(sin(2 * a0 + 0.6)), 3)
    let c = NSColor(hue: hue, saturation: 0.85, brightness: 1, alpha: strength).usingColorSpace(.displayP3)!
    let p = CGMutablePath()
    p.move(to: center)
    p.addArc(center: center, radius: outer + 2, startAngle: a0, endAngle: a1, clockwise: false)
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(c.cgColor)
    ctx.fillPath()
}
// Fine concentric "track" rings.
ctx.setLineWidth(1.2)
for r in stride(from: hub + 18, to: outer - 6, by: 9) {
    ctx.setStrokeColor(rgb(0xFFFFFF, r.truncatingRemainder(dividingBy: 18) < 9 ? 0.10 : 0.05))
    ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
}
// Specular highlight across the upper left.
ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.45)), (0.4, rgb(0xFFFFFF, 0)), (1, rgb(0xFFFFFF, 0))]),
                       start: CGPoint(x: center.x - outer, y: center.y - outer),
                       end: CGPoint(x: center.x + outer, y: center.y + outer), options: [])
ctx.restoreGState()

// Clear plastic hub and the centre hole.
ctx.saveGState()
ctx.addPath(ring(hub, hole))
ctx.clip(using: .evenOdd)
ctx.drawRadialGradient(gradient([(0, rgb(0xD9DCE6, 0.55)), (1, rgb(0x8C91A3, 0.75))]),
                       startCenter: center, startRadius: hole, endCenter: center, endRadius: hub, options: [])
ctx.restoreGState()
ctx.setLineWidth(3)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.55))
ctx.strokeEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: 2 * hub, height: 2 * hub))
ctx.setStrokeColor(rgb(0x5A5F73, 0.9))
ctx.strokeEllipse(in: CGRect(x: center.x - hole, y: center.y - hole, width: 2 * hole, height: 2 * hole))
ctx.setLineWidth(2.5)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.6))
ctx.strokeEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer))

// MARK: Anvil

let anvil = CGMutablePath()
// Face (top), horn to the left, heel to the right, waist, and foot.
anvil.move(to: CGPoint(x: 330, y: 660))
anvil.addLine(to: CGPoint(x: 790, y: 660))      // top face
anvil.addLine(to: CGPoint(x: 790, y: 716))      // heel
anvil.addLine(to: CGPoint(x: 668, y: 728))
anvil.addCurve(to: CGPoint(x: 630, y: 790), control1: CGPoint(x: 632, y: 740), control2: CGPoint(x: 626, y: 768))
anvil.addLine(to: CGPoint(x: 712, y: 822))      // foot right
anvil.addLine(to: CGPoint(x: 712, y: 852))
anvil.addLine(to: CGPoint(x: 312, y: 852))
anvil.addLine(to: CGPoint(x: 312, y: 822))      // foot left
anvil.addLine(to: CGPoint(x: 394, y: 790))
anvil.addCurve(to: CGPoint(x: 356, y: 728), control1: CGPoint(x: 398, y: 768), control2: CGPoint(x: 392, y: 740))
anvil.addCurve(to: CGPoint(x: 196, y: 672), control1: CGPoint(x: 300, y: 716), control2: CGPoint(x: 236, y: 700))  // horn underside
anvil.addCurve(to: CGPoint(x: 330, y: 660), control1: CGPoint(x: 236, y: 662), control2: CGPoint(x: 290, y: 658))  // horn top
anvil.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x000000, 0.6))
ctx.addPath(anvil)
ctx.setFillColor(rgb(0x2B2E3A))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(anvil)
ctx.clip()
ctx.drawLinearGradient(gradient([(0, rgb(0x6A6F80)), (0.12, rgb(0x3A3E4D)), (1, rgb(0x1A1C25))]),
                       start: CGPoint(x: 512, y: 660), end: CGPoint(x: 512, y: 852), options: [])
// Glowing hot spot on the face where the disc rests.
ctx.drawRadialGradient(gradient([(0, rgb(0xFFE08A, 0.95)), (0.25, rgb(0xFF8A1E, 0.75)), (1, rgb(0xFF4D00, 0))]),
                       startCenter: CGPoint(x: 512, y: 664), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 664), endRadius: 190, options: [])
ctx.restoreGState()
// Bright edge on the anvil face.
ctx.setLineWidth(4)
ctx.setStrokeColor(rgb(0xFFB25C, 0.85))
ctx.move(to: CGPoint(x: 300, y: 661))
ctx.addLine(to: CGPoint(x: 788, y: 661))
ctx.strokePath()

// MARK: Sparks

ctx.setBlendMode(.screen)
ctx.drawRadialGradient(gradient([(0, rgb(0xFFD27A, 0.9)), (0.3, rgb(0xFF7A1A, 0.45)), (1, rgb(0xFF4D00, 0))]),
                       startCenter: CGPoint(x: 512, y: 662), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 662), endRadius: 120, options: [])
ctx.setBlendMode(.normal)
let sparks: [(CGFloat, CGFloat, CGFloat)] = [  // angle (deg, 0 = right, up negative), length, width
    (-168, 250, 7), (-152, 190, 6), (-137, 285, 6.5), (-118, 150, 5), (-12, 250, 7), (-28, 195, 6),
    (-43, 290, 6.5), (-62, 150, 5), (-176, 140, 4.5), (-4, 150, 4.5),
]
for (deg, length, width) in sparks {
    let a = deg * .pi / 180
    let start = CGPoint(x: 512 + cos(a) * 46, y: 652 + sin(a) * 24)
    let end = CGPoint(x: start.x + cos(a) * length, y: start.y + sin(a) * length)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: rgb(0xFF6A00, 0.95))
    // Tapered streak: thick and hot at the head, fading toward the anvil.
    let streak = CGMutablePath()
    let normal = CGPoint(x: -sin(a), y: cos(a))
    streak.move(to: start)
    streak.addLine(to: CGPoint(x: end.x + normal.x * width / 2, y: end.y + normal.y * width / 2))
    streak.addLine(to: CGPoint(x: end.x - normal.x * width / 2, y: end.y - normal.y * width / 2))
    streak.closeSubpath()
    ctx.addPath(streak)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFF7A1A, 0.2)), (0.7, rgb(0xFFA531)), (1, rgb(0xFFE7A8))]),
                           start: start, end: end, options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 12, color: rgb(0xFF8A1E))
    ctx.setFillColor(rgb(0xFFF6D8))
    ctx.fillEllipse(in: CGRect(x: end.x - width * 0.7, y: end.y - width * 0.7, width: width * 1.4, height: width * 1.4))
    ctx.restoreGState()
}

// MARK: Write

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: out))
print("wrote \(out)")
