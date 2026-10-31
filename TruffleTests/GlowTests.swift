import UIKit
import XCTest
@testable import Truffle

final class GlowTests: XCTestCase {
    private let start: TimeInterval = 800_000_000
    private let frame: TimeInterval = 1.0 / 30
    private let bulbs = 14

    private func level(_ bulb: Int, _ time: TimeInterval) -> Double {
        LightShow.level(bulb: bulb, of: bulbs, colors: 4, at: time)
    }

    func testTheLightsEaseOnAndOffInsteadOfStrobing() {
        let program = LightShow.length * Double(LightShow.Pattern.allCases.count)
        for bulb in 0..<bulbs {
            var previous = level(bulb, start)
            var lowest = previous, highest = previous
            for step in 1...Int(program * 2 / frame) {
                let now = level(bulb, start + Double(step) * frame)
                XCTAssertLessThanOrEqual(abs(now - previous), 0.15, "bulb \(bulb) jumps at frame \(step)")
                XCTAssert((0...1).contains(now))
                lowest = min(lowest, now)
                highest = max(highest, now)
                previous = now
            }
            XCTAssertLessThan(lowest, 0.2, "bulb \(bulb) goes out")
            XCTAssertGreaterThan(highest, 0.9, "bulb \(bulb) comes on")
        }
    }

    func testTheControllerPlaysEveryPatternInTurn() {
        let middles = LightShow.Pattern.allCases.indices.map { start + (Double($0) + 0.5) * LightShow.length }
        XCTAssertEqual(Set(middles.map(LightShow.pattern(at:))).count, LightShow.Pattern.allCases.count)
    }

    func testTheChaseRunsAlongTheString() throws {
        let slot = try XCTUnwrap((0..<10).first { LightShow.pattern(at: start + Double($0) * LightShow.length) == .chase })
        let time = start + Double(slot) * LightShow.length + 3
        let brightest = (0..<3).map { step in
            (0..<4).max { level($0, time + Double(step) * 0.6) < level($1, time + Double(step) * 0.6) }!
        }
        XCTAssertEqual(brightest[1], (brightest[0] + 1) % 4, "a quarter of the way on, the next color is lit")
        XCTAssertEqual(brightest[2], (brightest[0] + 2) % 4)
    }

    func testTheCandleSwellsAndFlickersWithoutJumping() {
        var previous = Candle.flame(at: start)
        var lowest = previous, highest = previous
        var swells = 0
        for step in 1...Int(120 / frame) {
            let now = Candle.flame(at: start + Double(step) * frame)
            XCTAssertLessThanOrEqual(abs(now - previous), 0.1, "the flame jumps at frame \(step)")
            if previous < 0.6, now >= 0.6 { swells += 1 }
            lowest = min(lowest, now)
            highest = max(highest, now)
            previous = now
        }
        XCTAssertLessThan(lowest, 0.35, "it sinks dim")
        XCTAssertGreaterThan(highest, 0.85, "it swells bright")
        XCTAssertGreaterThan(swells, 10, "brighter, then dimmer, over and over in two minutes")
    }

    /// The masks are cut from the drawing; if the jack-o'-lantern is redrawn without
    /// `generate-art.py glow`, the glow would float off its face.
    func testTheCandleMasksSitOnTheCarvedFace() throws {
        let drawing = try pixels("Prop-jackOLantern")
        for mask in ["Prop-jackOLanternFace", "Prop-jackOLanternBloom"] {
            let light = try pixels(mask)
            XCTAssertEqual(light.width, drawing.width, mask)
            XCTAssertEqual(light.height, drawing.height, mask)
        }
        let face = try pixels("Prop-jackOLanternFace")
        var covered = 0, onYellow = 0
        for index in 0..<(face.width * face.height) where face.bytes[index * 4 + 3] > 128 {
            covered += 1
            let red = Double(drawing.bytes[index * 4]), green = Double(drawing.bytes[index * 4 + 1])
            if red > 180, green / red > 0.55 { onYellow += 1 }
        }
        XCTAssertGreaterThan(covered, 2000, "the eyes, nose and mouth")
        XCTAssertGreaterThan(Double(onYellow) / Double(covered), 0.9, "the face mask lies on the drawing's lit openings")
    }

    private func pixels(_ name: String) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let image = try XCTUnwrap(UIImage(named: name)?.cgImage, name)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Back out the premultiplied alpha, so a pixel's color reads the same at any coverage.
        for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] > 0 && bytes[index + 3] < 255 {
            let alpha = Double(bytes[index + 3]) / 255
            for channel in 0..<3 { bytes[index + channel] = UInt8(min(255, Double(bytes[index + channel]) / alpha)) }
        }
        return (width, height, bytes)
    }
}
