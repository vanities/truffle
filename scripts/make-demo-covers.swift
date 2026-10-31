// Draws the demo library's album covers and artist portraits from scripts/demo-catalog.json.
// swift scripts/make-demo-covers.swift scripts/demo-catalog.json demo-library
import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

struct Catalog: Decodable {
    struct Artist: Decodable {
        let name: String
        let colors: [String]
        let albums: [Album]
    }

    struct Album: Decodable {
        let title: String
        let year: Int
        let style: String
        let colors: [String]
    }

    let artists: [Artist]
}

func slug(_ text: String) -> String {
    let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    return folded.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        .split(separator: "-").joined(separator: "-")
}

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// A repeatable random stream per cover, so re-running draws the same art.
struct Random {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

let side: CGFloat = 600
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func canvas() -> CGContext {
    CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func gradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func glow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
    let g = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func drawArt(_ ctx: CGContext, style: String, colors c: [CGColor], random: inout Random) {
    let top = CGPoint(x: 0, y: side), bottom = CGPoint(x: 0, y: 0)
    switch style {
    case "sun":
        gradient(ctx, [c[0], c[1], c[2]], from: top, to: bottom)
        let sun = CGRect(x: side * 0.22, y: side * 0.3, width: side * 0.56, height: side * 0.56)
        ctx.saveGState()
        ctx.addEllipse(in: sun)
        ctx.clip()
        gradient(ctx, [c[2], c[1]], from: CGPoint(x: 0, y: sun.maxY), to: CGPoint(x: 0, y: sun.minY))
        ctx.restoreGState()
        ctx.setFillColor(c[0])
        for band in 0..<6 {
            let y = side * 0.3 + CGFloat(band) * 22
            ctx.fill(CGRect(x: 0, y: y, width: side, height: CGFloat(4 + band * 2)))
        }
    case "rings":
        gradient(ctx, [c[0], c[1]], from: top, to: bottom)
        let center = CGPoint(x: side * (0.35 + random.next() * 0.3), y: side * (0.45 + random.next() * 0.2))
        for ring in stride(from: 360, to: 20, by: -26) {
            ctx.setStrokeColor(ring % 52 == 0 ? c[2] : c[2].copy(alpha: 0.35)!)
            ctx.setLineWidth(ring % 52 == 0 ? 9 : 4)
            ctx.strokeEllipse(in: CGRect(x: center.x - CGFloat(ring), y: center.y - CGFloat(ring), width: CGFloat(ring * 2), height: CGFloat(ring * 2)))
        }
        glow(ctx, center: center, radius: 120, color: c[2].copy(alpha: 0.6)!)
    case "waves":
        gradient(ctx, [c[0], c[1]], from: top, to: bottom)
        for layer in 0..<7 {
            let base = side * (0.15 + CGFloat(layer) * 0.1)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: base))
            for x in stride(from: 0, through: side, by: 6) {
                path.addLine(to: CGPoint(x: x, y: base + sin(x / 60 + CGFloat(layer) * 1.3) * 26))
            }
            path.addLine(to: CGPoint(x: side, y: 0))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(c[layer % 2 == 0 ? 2 : 1].copy(alpha: 0.14 + CGFloat(layer) * 0.05)!)
            ctx.fillPath()
        }
    case "grid":
        gradient(ctx, [c[0], c[1]], from: top, to: CGPoint(x: 0, y: side * 0.4))
        let horizon = side * 0.42
        glow(ctx, center: CGPoint(x: side / 2, y: horizon), radius: 220, color: c[2].copy(alpha: 0.8)!)
        ctx.setFillColor(c[0])
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: horizon))
        ctx.setStrokeColor(c[2].copy(alpha: 0.9)!)
        ctx.setLineWidth(2.5)
        for line in 0..<14 {
            let y = horizon * pow(CGFloat(line) / 14, 1.8)
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: side, y: y))
        }
        for column in -12...12 {
            ctx.move(to: CGPoint(x: side / 2 + CGFloat(column) * 18, y: horizon))
            ctx.addLine(to: CGPoint(x: side / 2 + CGFloat(column) * 110, y: 0))
        }
        ctx.strokePath()
    case "moon":
        gradient(ctx, [c[0], c[1]], from: top, to: bottom)
        for _ in 0..<70 {
            let x = random.next() * side, y = side * 0.35 + random.next() * side * 0.65, r = 0.8 + random.next() * 1.8
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.4 + random.next() * 0.5))
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
        }
        let moon = CGPoint(x: side * 0.66, y: side * 0.66)
        glow(ctx, center: moon, radius: 190, color: c[2].copy(alpha: 0.45)!)
        ctx.setFillColor(c[2])
        ctx.fillEllipse(in: CGRect(x: moon.x - 90, y: moon.y - 90, width: 180, height: 180))
        ctx.setFillColor(c[1].copy(alpha: 0.25)!)
        for (dx, dy, r) in [(-30.0, 20.0, 22.0), (25.0, -25.0, 15.0), (10.0, 40.0, 10.0)] {
            ctx.fillEllipse(in: CGRect(x: moon.x + dx - r, y: moon.y + dy - r, width: r * 2, height: r * 2))
        }
        let hills = CGMutablePath()
        hills.move(to: .zero)
        hills.addLine(to: CGPoint(x: 0, y: side * 0.24))
        hills.addCurve(to: CGPoint(x: side, y: side * 0.2), control1: CGPoint(x: side * 0.3, y: side * 0.36), control2: CGPoint(x: side * 0.6, y: side * 0.08))
        hills.addLine(to: CGPoint(x: side, y: 0))
        hills.closeSubpath()
        ctx.addPath(hills)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.85))
        ctx.fillPath()
    case "flame":
        gradient(ctx, [c[0], c[0], c[1]], from: top, to: bottom)
        let center = CGPoint(x: side / 2, y: side * 0.52)
        glow(ctx, center: center, radius: 260, color: c[2].copy(alpha: 0.55)!)
        let flame = CGMutablePath()
        flame.move(to: CGPoint(x: center.x, y: center.y + 150))
        flame.addCurve(to: CGPoint(x: center.x, y: center.y - 60), control1: CGPoint(x: center.x + 95, y: center.y + 40), control2: CGPoint(x: center.x + 70, y: center.y - 60))
        flame.addCurve(to: CGPoint(x: center.x, y: center.y + 150), control1: CGPoint(x: center.x - 70, y: center.y - 60), control2: CGPoint(x: center.x - 95, y: center.y + 40))
        ctx.saveGState()
        ctx.addPath(flame)
        ctx.clip()
        gradient(ctx, [c[2], CGColor(srgbRed: 1, green: 0.95, blue: 0.75, alpha: 1)], from: CGPoint(x: 0, y: center.y + 150), to: CGPoint(x: 0, y: center.y - 60))
        ctx.restoreGState()
        ctx.setFillColor(c[1])
        ctx.fill(CGRect(x: center.x - 55, y: center.y - 240, width: 110, height: 180))
    case "petals":
        gradient(ctx, [c[1], c[0]], from: top, to: bottom)
        for _ in 0..<26 {
            let x = random.next() * side, y = random.next() * side, w = 18 + random.next() * 36
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: random.next() * .pi * 2)
            ctx.setFillColor(c[2].copy(alpha: 0.55 + random.next() * 0.4)!)
            ctx.fillEllipse(in: CGRect(x: -w / 2, y: -w / 4, width: w, height: w / 2))
            ctx.restoreGState()
        }
    default:
        gradient(ctx, [c[0], c[1]], from: top, to: bottom)
        for _ in 0..<90 {
            let x = random.next() * side, y = random.next() * side, r = 2 + random.next() * 5
            ctx.setFillColor(c[2].copy(alpha: 0.4 + random.next() * 0.6)!)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
        }
        ctx.setFillColor(c[2].copy(alpha: 0.9)!)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side * 0.14))
    }
}

func drawText(_ ctx: CGContext, title: String, artist: String, light: Bool) {
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 10
    let titleFont = NSFont.systemFont(ofSize: title.count > 16 ? 46 : 58, weight: .black)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    let titleText = NSAttributedString(string: title, attributes: [
        .font: titleFont, .foregroundColor: NSColor.white, .shadow: shadow, .paragraphStyle: paragraph, .kern: -1.2,
    ])
    let artistText = NSAttributedString(string: artist.uppercased(), attributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .heavy), .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        .kern: 3.5, .shadow: shadow,
    ])
    let box = CGRect(x: 36, y: 40, width: side - 72, height: 170)
    let bounds = titleText.boundingRect(with: box.size, options: [.usesLineFragmentOrigin])
    titleText.draw(with: CGRect(x: box.minX, y: box.minY, width: box.width, height: bounds.height), options: [.usesLineFragmentOrigin])
    artistText.draw(at: CGPoint(x: box.minX + 2, y: box.minY + bounds.height + 10))
    NSGraphicsContext.restoreGraphicsState()
}

func write(_ ctx: CGContext, to url: URL) {
    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        fatalError("can't write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    CGImageDestinationFinalize(destination)
}

let arguments = CommandLine.arguments
let catalogURL = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "scripts/demo-catalog.json")
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "demo-library")
let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
let covers = output.appending(path: "covers"), portraits = output.appending(path: "artists")
try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: portraits, withIntermediateDirectories: true)

var count = 0
for artist in catalog.artists {
    for album in artist.albums {
        var random = Random(state: UInt64(abs(album.title.hashValue % 1_000_000)) &+ 7)
        random.state = album.title.unicodeScalars.reduce(1469598103934665603) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        let ctx = canvas()
        drawArt(ctx, style: album.style, colors: album.colors.map { color($0) }, random: &random)
        // A soft dark band at the bottom keeps the title readable on any art.
        gradient(ctx, [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.45)], from: CGPoint(x: 0, y: side * 0.45), to: CGPoint(x: 0, y: 0))
        drawText(ctx, title: album.title, artist: artist.name, light: true)
        write(ctx, to: covers.appending(path: slug(album.title) + ".jpg"))
        count += 1
    }
    // Portrait: the artist's colors with their initials, like a moody band photo stand-in.
    let ctx = canvas()
    let colors = artist.colors.map { color($0) }
    gradient(ctx, [colors[2], colors[1], colors[0]], from: CGPoint(x: side, y: side), to: .zero)
    glow(ctx, center: CGPoint(x: side * 0.3, y: side * 0.7), radius: 300, color: colors[2].copy(alpha: 0.6)!)
    let initials = artist.name.split(separator: " ").filter { $0.first?.isLetter == true && $0 != "The" && $0 != "&" }
        .prefix(2).compactMap(\.first).map(String.init).joined()
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let text = NSAttributedString(string: initials, attributes: [
        .font: NSFont.systemFont(ofSize: 220, weight: .black), .foregroundColor: NSColor.white.withAlphaComponent(0.9), .kern: -8,
    ])
    let size = text.size()
    text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    write(ctx, to: portraits.appending(path: slug(artist.name) + ".jpg"))
}
print("drew \(count) covers and \(catalog.artists.count) portraits into \(output.path)")
