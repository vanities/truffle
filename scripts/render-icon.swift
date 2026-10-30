// Renders Truffle's app icon offline: a record on a dusk gradient, shuffle arrows on the label.
// swift scripts/render-icon.swift Truffle/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

let side = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }
let full = CGFloat(side)
let center = CGPoint(x: full / 2, y: full / 2)

// Dusk: deep plum at the top left, ember in the middle, amber at the bottom right.
let sky = CGGradient(colorsSpace: space, colors: [rgb(0x24103A), rgb(0x7A2440), rgb(0xF0923A)] as CFArray,
                     locations: [0, 0.58, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: full), end: CGPoint(x: full, y: 0), options: [])
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFC37A, 0.55), rgb(0xFFC37A, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: full * 0.72, y: full * 0.3), startRadius: 0,
                       endCenter: CGPoint(x: full * 0.72, y: full * 0.3), endRadius: full * 0.6, options: [])

// The record, with a soft drop shadow.
let radius: CGFloat = 372
let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -28), blur: 70, color: rgb(0x000000, 0.5))
ctx.setFillColor(rgb(0x120A0E))
ctx.fillEllipse(in: disc)
ctx.restoreGState()

ctx.saveGState()
ctx.addEllipse(in: disc)
ctx.clip()
let vinyl = CGGradient(colorsSpace: space, colors: [rgb(0x2A1A20), rgb(0x0E080B)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(vinyl, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
// Grooves.
ctx.setLineWidth(2.2)
var groove = radius - 22
while groove > 168 {
    ctx.setStrokeColor(rgb(0xFFFFFF, groove.truncatingRemainder(dividingBy: 3) < 1 ? 0.07 : 0.035))
    ctx.strokeEllipse(in: CGRect(x: center.x - groove, y: center.y - groove, width: groove * 2, height: groove * 2))
    groove -= 13
}
// A sheen across the grooves, like light catching a spinning record.
let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0), rgb(0xFFD9A8, 0.22), rgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 0.5, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: disc.minX, y: disc.maxY), end: CGPoint(x: disc.maxX, y: disc.minY), options: [])
ctx.restoreGState()

// The label.
let labelRadius: CGFloat = 158
let label = CGRect(x: center.x - labelRadius, y: center.y - labelRadius, width: labelRadius * 2, height: labelRadius * 2)
ctx.saveGState()
ctx.addEllipse(in: label)
ctx.clip()
let amber = CGGradient(colorsSpace: space, colors: [rgb(0xFFB45C), rgb(0xE8692A)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(amber, start: CGPoint(x: label.minX, y: label.maxY), end: CGPoint(x: label.maxX, y: label.minY), options: [])
ctx.restoreGState()

// Shuffle arrows in white on the label.
let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let config = NSImage.SymbolConfiguration(pointSize: 150, weight: .heavy)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "shuffle", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let size = symbol.size
    symbol.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
}
NSGraphicsContext.restoreGraphicsState()

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("can't write \(output)") }
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(output)")
