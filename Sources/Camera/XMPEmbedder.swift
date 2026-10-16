import Foundation

/// Embeds an XMP packet into a TIFF-container RAW (CR2) without disturbing any
/// existing byte of the file. License-clean (ours, MIT), no Exiv2 (GPL), no
/// exiftool (Perl), and Apple's ImageIO refuses CR2 as a write destination.
///
/// Strategy: append-only splice. The packet (and, if IFD0 has no XMP tag yet,
/// a rebuilt copy of IFD0) is appended at end-of-file. The only bytes that
/// change inside the original extent are a single pointer patch:
///   - XMP tag (700) already present: that entry's count+offset fields (8 bytes)
///   - XMP tag absent: the header's IFD0 pointer (4 bytes at offset 4), which
///     is re-aimed at the rebuilt IFD0 in the appended tail
/// Every other structure (EXIF, MakerNotes, sensor strips, embedded JPEGs)
/// keeps its exact offset, which is what makes this safe where naive TIFF
/// rewriting is not: Canon MakerNotes contain absolute file offsets that break
/// if anything shifts.
///
/// The dead bytes left behind (the old IFD0 or old packet) are unreferenced
/// and harmless. Repeated re-embeds grow the file by the packet size only.
///
/// Scope gate: little-endian classic TIFF only (every CR2 is II/42). Anything
/// else, big-endian, BigTIFF, CR3/ISO-BMFF, throws `.unsupportedContainer`
/// and the caller falls back to the sidecar. Never guess on an unknown layout.
public enum XMPEmbedder {

    public enum EmbedError: Error, Equatable {
        case unsupportedContainer(String)
        case malformed(String)
        case verifyFailed(String)
    }

    static let xmpTag: UInt16 = 700

    // MARK: - Little-endian readers/writers

    private static func u16(_ d: Data, _ off: Int) throws -> UInt16 {
        guard off + 2 <= d.count else { throw EmbedError.malformed("u16 read past EOF at \(off)") }
        return UInt16(d[d.startIndex + off]) | (UInt16(d[d.startIndex + off + 1]) << 8)
    }

    private static func u32(_ d: Data, _ off: Int) throws -> UInt32 {
        guard off + 4 <= d.count else { throw EmbedError.malformed("u32 read past EOF at \(off)") }
        return UInt32(d[d.startIndex + off])
            | (UInt32(d[d.startIndex + off + 1]) << 8)
            | (UInt32(d[d.startIndex + off + 2]) << 16)
            | (UInt32(d[d.startIndex + off + 3]) << 24)
    }

    private static func putU32(_ d: inout Data, _ off: Int, _ v: UInt32) {
        d[d.startIndex + off]     = UInt8(v & 0xFF)
        d[d.startIndex + off + 1] = UInt8((v >> 8) & 0xFF)
        d[d.startIndex + off + 2] = UInt8((v >> 16) & 0xFF)
        d[d.startIndex + off + 3] = UInt8((v >> 24) & 0xFF)
    }

    private static func appendU16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8))
    }

    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
    }

    // MARK: - Embed (in memory)

    /// Returns a new Data with `packet` embedded as IFD0 tag 700. The input is
    /// never mutated. Throws on non-CR2-shaped containers and on any internal
    /// verification failure, and the caller keeps the original file untouched.
    public static func embed(packet: String, into original: Data) throws -> Data {
        guard original.count >= 16 else { throw EmbedError.malformed("file too small") }
        guard original[original.startIndex] == 0x49, original[original.startIndex + 1] == 0x49 else {
            throw EmbedError.unsupportedContainer("not little-endian TIFF (II)")
        }
        guard try u16(original, 2) == 42 else {
            throw EmbedError.unsupportedContainer("not classic TIFF (magic != 42)")
        }
        let ifd0Offset = Int(try u32(original, 4))
        let entryCount = Int(try u16(original, ifd0Offset))
        guard entryCount > 0, entryCount < 1024 else {
            throw EmbedError.malformed("implausible IFD0 entry count \(entryCount)")
        }
        let entriesStart = ifd0Offset + 2
        let nextIFDFieldOffset = entriesStart + entryCount * 12
        let nextIFD = try u32(original, nextIFDFieldOffset)

        guard let packetBytes = packet.data(using: .utf8) else {
            throw EmbedError.malformed("packet not UTF-8 encodable")
        }

        var out = original

        // Word-align the appended packet (TIFF value offsets must be even).
        if out.count % 2 != 0 { out.append(0) }
        let packetOffset = UInt32(out.count)
        out.append(packetBytes)

        // Locate an existing XMP entry, and the sorted insert position if absent.
        var existingEntryOffset: Int? = nil
        var insertIndex = entryCount
        for i in 0..<entryCount {
            let e = entriesStart + i * 12
            let tag = try u16(original, e)
            if tag == xmpTag { existingEntryOffset = e; break }
            if tag > xmpTag { insertIndex = min(insertIndex, i) }
        }

        if let e = existingEntryOffset {
            // Re-aim the existing entry at the appended packet: 8 bytes patched
            // (count at e+4, value offset at e+8). The type field is left as
            // is. BYTE (1) and UNDEFINED (7) are both seen in the wild and
            // readers accept either.
            putU32(&out, e + 4, UInt32(packetBytes.count))
            putU32(&out, e + 8, packetOffset)
        } else {
            // Rebuild IFD0 with one extra entry, appended at EOF, and patch the
            // header's IFD0 pointer. Original IFD0 becomes dead space. Entries
            // are copied verbatim, their value offsets are absolute and still
            // valid because nothing moved.
            if out.count % 2 != 0 { out.append(0) }
            let newIFDOffset = UInt32(out.count)
            appendU16(&out, UInt16(entryCount + 1))
            for i in 0..<entryCount {
                if i == insertIndex { appendXMPEntry(&out, count: UInt32(packetBytes.count), offset: packetOffset) }
                let e = entriesStart + i * 12
                out.append(original.subdata(in: (original.startIndex + e)..<(original.startIndex + e + 12)))
            }
            if insertIndex == entryCount { appendXMPEntry(&out, count: UInt32(packetBytes.count), offset: packetOffset) }
            appendU32(&out, nextIFD)
            putU32(&out, 4, newIFDOffset)
        }

        try verify(out, against: original, expectPacket: packetBytes)
        return out
    }

    private static func appendXMPEntry(_ d: inout Data, count: UInt32, offset: UInt32) {
        appendU16(&d, xmpTag)
        appendU16(&d, 1)          // type BYTE
        appendU32(&d, count)
        appendU32(&d, offset)
    }

    // MARK: - Verification

    /// Re-parse the spliced file and check (a) the packet reads back
    /// byte-identical via the normal IFD walk, and (b) at most 8 bytes of the
    /// original extent changed, all within one 8-byte span, either inside the header's IFD0
    /// pointer (offsets 4 to 7) or past the header. The check does not confirm
    /// that bytes past the header are the XMP entry's count and offset.
    private static func verify(_ out: Data, against original: Data, expectPacket: Data) throws {
        let ifd0 = Int(try u32(out, 4))
        let n = Int(try u16(out, ifd0))
        var found: Data? = nil
        for i in 0..<n {
            let e = ifd0 + 2 + i * 12
            if try u16(out, e) == xmpTag {
                let count = Int(try u32(out, e + 4))
                let off = Int(try u32(out, e + 8))
                guard off + count <= out.count else { throw EmbedError.verifyFailed("XMP extends past EOF") }
                found = out.subdata(in: (out.startIndex + off)..<(out.startIndex + off + count))
                break
            }
        }
        guard found == expectPacket else { throw EmbedError.verifyFailed("packet read-back mismatch") }

        // Diff audit over the original extent: collect every changed offset and
        // require a span of at most 8 bytes, all in the header pointer or all
        // past the header.
        var changed: [Int] = []
        for i in 0..<original.count where out[out.startIndex + i] != original[original.startIndex + i] {
            changed.append(i)
            if changed.count > 8 { throw EmbedError.verifyFailed("more than 8 bytes changed in original extent") }
        }
        if changed.isEmpty { throw EmbedError.verifyFailed("no pointer patch found, packet unreachable") }
        let span = changed.min()!...changed.max()!
        let headerPatch = 4...7
        let entryPatchOK = changed.allSatisfy { $0 >= 8 }  // all past the header
        guard span.count <= 8, (changed.allSatisfy { headerPatch.contains($0) } || entryPatchOK) else {
            throw EmbedError.verifyFailed("changed bytes outside sanctioned patch region: \(changed)")
        }
    }

    // MARK: - File-level embed (copy → splice → atomic swap)

    /// Embed into the file at `url` safely: splice in memory, write to a temp
    /// file in the same directory, then atomically replace. On any error the
    /// original file is untouched.
    public static func embedFile(packet: String, at url: URL) throws {
        let original = try Data(contentsOf: url)
        let spliced = try embed(packet: packet, into: original)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).xmpembed.tmp")
        try spliced.write(to: tmp, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
