import XCTest
@testable import Camera

/// The append-only XMP splicer.
final class XMPEmbedderTests: XCTestCase {

    /// Build a minimal valid little-endian TIFF:
    /// header → IFD0 (ImageWidth=256 [tag 256], StripOffsets blob pointer
    /// [tag 273]) → payload blob. Returns (data, payloadRange).
    private func makeTIFF(withXMP existing: Data? = nil) -> (Data, Range<Int>) {
        var d = Data()
        func u16(_ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }

        let payload = Data(repeating: 0xAB, count: 64)
        let entryCount = existing == nil ? 2 : 3
        let ifd0 = 8
        let afterIFD = ifd0 + 2 + entryCount * 12 + 4
        let payloadOffset = afterIFD
        let xmpOffset = payloadOffset + payload.count

        d.append(contentsOf: [0x49, 0x49]); u16(42); u32(UInt32(ifd0))
        u16(UInt16(entryCount))
        // tag 256 ImageWidth, SHORT, inline
        u16(256); u16(3); u32(1); u32(256)
        // tag 273 pointer to payload
        u16(273); u16(4); u32(1); u32(UInt32(payloadOffset))
        if let existing {
            u16(700); u16(1); u32(UInt32(existing.count)); u32(UInt32(xmpOffset))
        }
        u32(0) // next IFD
        XCTAssertEqual(d.count, afterIFD)
        d.append(payload)
        if let existing { d.append(existing) }
        return (d, payloadOffset..<(payloadOffset + payload.count))
    }

    private func readBackXMP(_ d: Data) throws -> Data {
        func u16(_ off: Int) -> Int { Int(d[off]) | (Int(d[off + 1]) << 8) }
        func u32(_ off: Int) -> Int {
            Int(d[off]) | (Int(d[off + 1]) << 8) | (Int(d[off + 2]) << 16) | (Int(d[off + 3]) << 24)
        }
        let ifd0 = u32(4)
        for i in 0..<u16(ifd0) {
            let e = ifd0 + 2 + i * 12
            if u16(e) == 700 { return d.subdata(in: u32(e + 8)..<(u32(e + 8) + u32(e + 4))) }
        }
        throw XMPEmbedder.EmbedError.verifyFailed("no XMP tag in test read-back")
    }

    func testEmbedIntoTIFFWithoutXMPTag() throws {
        let (tiff, payloadRange) = makeTIFF()
        let packet = "<x:xmpmeta>test-packet</x:xmpmeta>"
        let out = try XMPEmbedder.embed(packet: packet, into: tiff)
        XCTAssertEqual(try readBackXMP(out), packet.data(using: .utf8))
        // Payload bytes unchanged at the same offsets (nothing moved).
        XCTAssertEqual(out.subdata(in: payloadRange), tiff.subdata(in: payloadRange))
        // Only the header IFD0 pointer changed inside the original extent.
        let changed = (0..<tiff.count).filter { out[$0] != tiff[$0] }
        XCTAssertTrue(changed.allSatisfy { (4...7).contains($0) }, "changed: \(changed)")
    }

    func testReEmbedReplacesExistingPacket() throws {
        let oldPacket = "<x:xmpmeta>OLD</x:xmpmeta>".data(using: .utf8)!
        let (tiff, payloadRange) = makeTIFF(withXMP: oldPacket)
        let newPacket = "<x:xmpmeta>NEW and longer than before</x:xmpmeta>"
        let out = try XMPEmbedder.embed(packet: newPacket, into: tiff)
        XCTAssertEqual(try readBackXMP(out), newPacket.data(using: .utf8))
        XCTAssertEqual(out.subdata(in: payloadRange), tiff.subdata(in: payloadRange))
        // Existing-tag path: at most 8 bytes patched, none in the header.
        let changed = (0..<tiff.count).filter { out[$0] != tiff[$0] }
        XCTAssertLessThanOrEqual(changed.count, 8)
        XCTAssertTrue(changed.allSatisfy { $0 >= 8 }, "header must be untouched: \(changed)")
    }

    func testEntriesStaySortedAfterInsert() throws {
        let (tiff, _) = makeTIFF()
        let out = try XMPEmbedder.embed(packet: "<p/>", into: tiff)
        func u16(_ off: Int) -> Int { Int(out[off]) | (Int(out[off + 1]) << 8) }
        func u32(_ off: Int) -> Int {
            Int(out[off]) | (Int(out[off + 1]) << 8) | (Int(out[off + 2]) << 16) | (Int(out[off + 3]) << 24)
        }
        let ifd0 = u32(4)
        let tags = (0..<u16(ifd0)).map { u16(ifd0 + 2 + $0 * 12) }
        XCTAssertEqual(tags, tags.sorted(), "IFD entries must stay tag-sorted")
        XCTAssertEqual(tags, [256, 273, 700])
    }

    func testBigEndianRefused() {
        var d = Data([0x4D, 0x4D, 0x00, 0x2A]) // MM big-endian
        d.append(Data(repeating: 0, count: 12))
        XCTAssertThrowsError(try XMPEmbedder.embed(packet: "<p/>", into: d)) { err in
            guard case XMPEmbedder.EmbedError.unsupportedContainer = err else {
                return XCTFail("expected unsupportedContainer, got \(err)")
            }
        }
    }

    func testGarbageRefusedWithoutCrash() {
        XCTAssertThrowsError(try XMPEmbedder.embed(packet: "<p/>", into: Data([0x49, 0x49, 0x2A, 0x00])))
    }
}
