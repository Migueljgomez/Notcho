// Draws the app icon: the black notch panel dropping open with the four pastel cards.
// Run: swift Icon/make-icon.swift Icon/icon-1024.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1) // draw top-down

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: 1) }

// Body: macOS icon grid (824 pt square, 100 pt margin), soft shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: NSColor.black.withAlphaComponent(0.25).cgColor)
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0.96, 0.95, 0.92).cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(bodyPath); ctx.clip()

// Notch panel hanging from the top edge, square top, rounded bottom.
let panel = CGRect(x: 192, y: 100, width: 640, height: 600)
let p = CGMutablePath(), r: CGFloat = 110
p.move(to: CGPoint(x: panel.minX, y: panel.minY))
p.addLine(to: CGPoint(x: panel.maxX, y: panel.minY))
p.addArc(tangent1End: CGPoint(x: panel.maxX, y: panel.maxY), tangent2End: CGPoint(x: panel.minX, y: panel.maxY), radius: r)
p.addArc(tangent1End: CGPoint(x: panel.minX, y: panel.maxY), tangent2End: CGPoint(x: panel.minX, y: panel.minY), radius: r)
p.closeSubpath()
ctx.addPath(p); ctx.setFillColor(rgb(0.07, 0.07, 0.08).cgColor); ctx.fillPath()

// Four cards, in the app's palette (sage, lavender, olive, blue).
let colors = [rgb(0.56, 0.68, 0.58), rgb(0.60, 0.57, 0.75), rgb(0.69, 0.66, 0.38), rgb(0.55, 0.66, 0.77)]
let pad: CGFloat = 44, gap: CGFloat = 28, top: CGFloat = 160
let w = (panel.width - pad * 2 - gap) / 2, h = (panel.maxY - top - pad - gap) / 2
for (i, c) in colors.enumerated() {
    let card = CGRect(x: panel.minX + pad + CGFloat(i % 2) * (w + gap), y: top + CGFloat(i / 2) * (h + gap), width: w, height: h)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.setFillColor(c.cgColor); ctx.fillPath()
}
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
