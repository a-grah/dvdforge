// Renders the release DMG's window background: the app name, an arrow from
// the app to the Applications link, and an install hint. Same look as the
// Balances DMG. release.sh lays the icons out to match (660×400 window,
// app at x 165, Applications at x 495, both at y 190). Finder shows only about
// the top 340 points: the window size includes the title and status bars.
//
//   swift Scripts/make-dmg-background.swift <out.png> <scale>
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let scale = CGFloat(Double(args[2]) ?? 1)
let size = CGSize(width: 660, height: 400)

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                           pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let flipped = NSAffineTransform()
flipped.translateX(by: 0, yBy: size.height)
flipped.scaleX(by: 1, yBy: -1)
flipped.concat()

// Background: a soft top-to-bottom gradient.
NSGradient(starting: rgb(0xEEF2F7), ending: rgb(0xDDE6EF))!
    .draw(in: NSRect(origin: .zero, size: size), angle: 90)

func centered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
    ]
    let s = NSAttributedString(string: text, attributes: attributes)
    let b = s.size()
    // Text draws upside down in a flipped context unless the context says it's flipped.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: NSGraphicsContext.current!.cgContext, flipped: true)
    s.draw(at: NSPoint(x: (660 - b.width) / 2, y: y - b.height / 2))
}

centered("dvdForge", y: 48, size: 24, weight: .regular, color: rgb(0x3B4558))
centered("Drag dvdForge into Applications to install", y: 318, size: 13, weight: .regular, color: rgb(0x6E7A8A))

// Arrow from the app icon (x 165) toward Applications (x 495), at icon height.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 260, y: 177))
arrow.line(to: NSPoint(x: 350, y: 177))
arrow.line(to: NSPoint(x: 350, y: 155))
arrow.line(to: NSPoint(x: 402, y: 190))
arrow.line(to: NSPoint(x: 350, y: 225))
arrow.line(to: NSPoint(x: 350, y: 203))
arrow.line(to: NSPoint(x: 260, y: 203))
arrow.close()
rgb(0x6B9FDA).setFill()
arrow.fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
