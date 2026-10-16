import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Scan

/// The per-frame exposure advisor: the clip trigger on synthetic frames,
/// the suggestion from the camera's own shutter list, and the hysteresis that
/// keeps the glyph from flickering.
final class ExposureAdvisorTests: XCTestCase {
    typealias A = ExposureAdvisor

    /// A wxh RGBA frame of mid gray. `clipCenter` pixels inside the central
    /// region and `clipOutside` pixels in the top band are set to white, or to
    /// 254 on one channel with `oneChannel`.
    private func frame(_ w: Int, _ h: Int, clipCenter: Int = 0, clipOutside: Int = 0, oneChannel: Bool = false) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = 128; px[i * 4 + 1] = 128; px[i * 4 + 2] = 128; px[i * 4 + 3] = 255 }
        func set(_ x: Int, _ y: Int) {
            let i = (y * w + x) * 4
            if oneChannel { px[i + 2] = 254 } else { px[i] = 255; px[i + 1] = 255; px[i + 2] = 255 }
        }
        var n = 0
        outer: for y in (h / 5 + 1)..<(h - h / 5 - 1) {
            for x in (w / 5 + 1)..<(w - w / 5 - 1) { if n >= clipCenter { break outer }; set(x, y); n += 1 }
        }
        n = 0
        outer2: for y in 0..<(h / 5) { for x in 0..<w { if n >= clipOutside { break outer2 }; set(x, y); n += 1 } }
        return px
    }

    // The central region of a 100x100 frame is 60x60 = 3600 pixels.

    func testNothingClippedIsZero() {
        XCTAssertEqual(A.clippedShare(rgba: frame(100, 100), width: 100, height: 100), 0)
    }

    func testTheShareCountsTheCenterOnly() {
        let s = A.clippedShare(rgba: frame(100, 100, clipCenter: 72), width: 100, height: 100)
        XCTAssertEqual(s, 72.0 / 3600, accuracy: 1e-9)
        let edge = A.clippedShare(rgba: frame(100, 100, clipOutside: 2000), width: 100, height: 100)
        XCTAssertEqual(edge, 0, "the rebate and the light box outside the center do not count")
    }

    func testAnyOneChannelAt254Counts() {
        let s = A.clippedShare(rgba: frame(100, 100, clipCenter: 36, oneChannel: true), width: 100, height: 100)
        XCTAssertEqual(s, 36.0 / 3600, accuracy: 1e-9)
    }

    func testTheGlyphShowsAbove1PercentAndNotAtIt() {
        var g = A.Gate()
        XCTAssertFalse(g.update(share: 0.01), "exactly 1% is not over the line")
        XCTAssertTrue(g.update(share: 0.0101))
    }

    /// A frame hovering around 1% must not blink the glyph on and off.
    func testHysteresisKeepsItFromFlickering() {
        var g = A.Gate()
        let readings = [0.012, 0.009, 0.011, 0.008, 0.0095, 0.006, 0.0051]
        XCTAssertTrue(readings.allSatisfy { g.update(share: $0) }, "stays on while above 0.5%")
        XCTAssertFalse(g.update(share: 0.0049), "goes below 0.5%")
        XCTAssertFalse(g.update(share: 0.009), "and does not come back until above 1% again")
        XCTAssertTrue(g.update(share: 0.02))
    }

    // MARK: - The suggestion, from the camera's own list

    /// An abridged 7D list, in the order libgphoto2 gives it, slow to fast
    /// (1/40 to 1/6400 left out).
    let sevenD = ["30", "25", "20", "15", "13", "10", "8", "6", "5", "4", "3.2", "2.5", "2", "1.6", "1.3", "1",
                  "0.8", "0.6", "0.5", "0.4", "0.3", "1/4", "1/5", "1/6", "1/8", "1/10", "1/13", "1/15", "1/20",
                  "1/25", "1/30", "1/8000", "bulb"]

    func testTheNextFasterShutterComesFromTheList() {
        XCTAssertEqual(A.nextFaster(than: "1/10", choices: sevenD), "1/13")
        XCTAssertEqual(A.nextFaster(than: "1/5", choices: sevenD), "1/6")
        XCTAssertEqual(A.nextFaster(than: "0.3", choices: sevenD), "1/4")
        XCTAssertEqual(A.nextFaster(than: "1/10", choices: Array(sevenD.reversed())), "1/13", "whatever order the list is in")
    }

    func testNoSuggestionAtTheFastestOrForANonTime() {
        XCTAssertNil(A.nextFaster(than: "1/8000", choices: sevenD))
        XCTAssertNil(A.nextFaster(than: "bulb", choices: sevenD))
        XCTAssertNil(A.nextFaster(than: "Auto", choices: sevenD))
    }

    func testShutterStringsParse() {
        XCTAssertEqual(A.seconds("1/13")!, 1.0 / 13, accuracy: 1e-12)
        XCTAssertEqual(A.seconds("0.3"), 0.3)
        XCTAssertEqual(A.seconds("30"), 30)
        XCTAssertNil(A.seconds("bulb"))
        XCTAssertNil(A.seconds("1/0"))
    }

    func testTheTooltipAndPopoverWording() {
        let a = A.advice(clippedShare: 0.032, current: "1/10", choices: sevenD)
        XCTAssertEqual(a.tooltip, "Highlights clip at 1/10, try 1/13")
        XCTAssertTrue(a.popover.hasPrefix("3.2% of the center of the frame clips at 1/10."), a.popover)
        XCTAssertTrue(a.popover.contains("1/13"))
        XCTAssertTrue(a.popover.hasSuffix("Double-click the sun to set it."), a.popover)
        XCTAssertFalse(a.popover.contains("Nothing changes"), a.popover)
        let top = A.advice(clippedShare: 0.02, current: "1/8000", choices: sevenD)
        XCTAssertEqual(top.tooltip, "Highlights clip at 1/8000")
        XCTAssertTrue(top.popover.contains("no faster shutter"), top.popover)
        XCTAssertFalse(top.popover.contains("Double-click"), top.popover)
    }

    /// A double-click sets the suggestion only when the shutter is ours to
    /// write, and does nothing at the fastest shutter.
    func testDoubleClickAppliesTheSuggestionOnlyWhenWritable() {
        let a = A.advice(clippedShare: 0.032, current: "1/10", choices: sevenD)
        XCTAssertEqual(a.shutterToApply(writable: true), "1/13")
        XCTAssertNil(a.shutterToApply(writable: false))
        let top = A.advice(clippedShare: 0.02, current: "1/8000", choices: sevenD)
        XCTAssertNil(top.shutterToApply(writable: true))
    }

    /// House style for one advice's tooltip and popover: no em-dash and no semicolon.
    func testTheCopyCarriesNoEmDashOrSemicolon() {
        let a = A.advice(clippedShare: 0.05, current: "1/10", choices: sevenD)
        for s in [a.tooltip, a.popover] {
            XCTAssertFalse(s.contains("\u{2014}"), s)
            XCTAssertFalse(s.contains(";"), s)
        }
    }

    // MARK: - Through a real JPEG

    func testAJPEGWithABlownCenterReadsAsClipped() throws {
        let w = 120, h = 80
        var px = frame(w, h)
        for y in 20..<60 { for x in 30..<90 { let i = (y * w + x) * 4; px[i] = 255; px[i + 1] = 255; px[i + 2] = 255 } }
        let jpeg = try XCTUnwrap(encodeJPEG(px, w, h))
        let s = try XCTUnwrap(A.clippedShare(jpeg: jpeg))
        XCTAssertGreaterThan(s, 0.5, "the blown block fills most of the center")
        let flat = try XCTUnwrap(encodeJPEG(frame(w, h), w, h))
        XCTAssertEqual(try XCTUnwrap(A.clippedShare(jpeg: flat)), 0, accuracy: 0.001)
    }

    private func encodeJPEG(_ rgba: [UInt8], _ w: Int, _ h: Int) -> Data? {
        var bytes = rgba
        let data = NSMutableData()
        let made: CGImage? = bytes.withUnsafeMutableBytes { p in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
        guard let img = made,
              let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
