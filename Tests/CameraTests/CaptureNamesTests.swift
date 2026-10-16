import XCTest
@testable import Camera

/// `CameraCapture.captureNames`: a capture never replaces a file already in the
/// capture folder.
final class CaptureNamesTests: XCTestCase {

    private let date: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 23
        comps.hour = 14; comps.minute = 35; comps.second = 7
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()

    private func names(_ pattern: String, start: Int, exts: [String?],
                       folder: Set<String>) -> CameraCapture.CaptureNames {
        CameraCapture.captureNames(pattern: pattern, timestamp: date, startingSequence: start,
                                   cameraExtensions: exts, exists: { folder.contains($0) })
    }

    /// Every `CameraCapture` starts its count at zero, and a new one is made at
    /// every connect and every relaunch. A second one writing into the same
    /// folder must count on past the first one's files.
    func testTheCountSkipsAcrossTwoFreshInstances() {
        var folder: Set<String> = []
        // The first instance: three shots, counted 1, 2, 3.
        var seq = 0
        for _ in 0..<3 {
            seq += 1
            let n = names("Roll12_{seq}.{ext}", start: seq, exts: ["CR2"], folder: folder)
            seq = n.sequence
            folder.formUnion(n.names)
        }
        XCTAssertEqual(folder, ["Roll12_0001.CR2", "Roll12_0002.CR2", "Roll12_0003.CR2"])

        // The second instance starts at 1 again.
        let next = names("Roll12_{seq}.{ext}", start: 1, exts: ["CR2"], folder: folder)
        XCTAssertEqual(next.names, ["Roll12_0004.CR2"])
        XCTAssertEqual(next.sequence, 4)
    }

    func testThirtySixFramesOnDiskMakeTheNextShotThirtySeven() {
        let folder = Set((1...36).map { String(format: "Roll12_%04d.CR2", $0) })
        let n = names("Roll12_{seq}.{ext}", start: 1, exts: ["CR2"], folder: folder)
        XCTAssertEqual(n.names, ["Roll12_0037.CR2"])
        XCTAssertEqual(n.sequence, 37)
    }

    /// A RAW plus JPEG capture keeps one number for both files, and skips as one
    /// when only one of its two names is taken.
    func testARawAndJpegPairShareOneNumberAndSkipTogether() {
        let free = names("Roll12_{seq}.{ext}", start: 1, exts: ["CR2", "JPG"], folder: [])
        XCTAssertEqual(free.names, ["Roll12_0001.CR2", "Roll12_0001.JPG"])

        let jpegTaken = names("Roll12_{seq}.{ext}", start: 1, exts: ["CR2", "JPG"],
                              folder: ["Roll12_0001.JPG"])
        XCTAssertEqual(jpegTaken.names, ["Roll12_0002.CR2", "Roll12_0002.JPG"])
        XCTAssertEqual(jpegTaken.sequence, 2)

        let rawTaken = names("Roll12_{seq}.{ext}", start: 1, exts: ["CR2", "JPG"],
                             folder: ["Roll12_0001.CR2"])
        XCTAssertEqual(rawTaken.names, ["Roll12_0002.CR2", "Roll12_0002.JPG"])
    }

    /// A sidecar left behind by a frame whose RAW is gone still holds that
    /// frame's metadata, so its number is taken.
    func testALeftoverSidecarBlocksItsNumber() {
        let n = names("Roll12_{seq}.{ext}", start: 1, exts: ["CR2"], folder: ["Roll12_0001.xmp"])
        XCTAssertEqual(n.names, ["Roll12_0002.CR2"])
        XCTAssertEqual(n.sequence, 2)

        let fixed = names("Scan.{ext}", start: 1, exts: ["CR2"], folder: ["Scan.xmp"])
        XCTAssertEqual(fixed.names, ["Scan_2.CR2"])
    }

    /// With no `{seq}` there is no number to skip, so the base name takes `_2`,
    /// then `_3`, the same suffix for every file of the capture.
    func testAPatternWithoutSeqGetsASuffix() {
        let first = names("Scan_{ymd}.{ext}", start: 1, exts: ["CR2", "JPG"], folder: [])
        XCTAssertEqual(first.names, ["Scan_20260523.CR2", "Scan_20260523.JPG"])

        var folder = Set(first.names)
        let second = names("Scan_{ymd}.{ext}", start: 2, exts: ["CR2", "JPG"], folder: folder)
        XCTAssertEqual(second.names, ["Scan_20260523_2.CR2", "Scan_20260523_2.JPG"])
        XCTAssertEqual(second.sequence, 2)

        folder.formUnion(second.names)
        let third = names("Scan_{ymd}.{ext}", start: 3, exts: ["CR2", "JPG"], folder: folder)
        XCTAssertEqual(third.names, ["Scan_20260523_3.CR2", "Scan_20260523_3.JPG"])

        // Only the JPEG name taken: both files still move to the same suffix.
        let pair = names("Scan.{ext}", start: 1, exts: ["CR2", "JPG"], folder: ["Scan.JPG"])
        XCTAssertEqual(pair.names, ["Scan_2.CR2", "Scan_2.JPG"])
    }

    /// The default pattern carries the time, and with nothing in the way its
    /// names are exactly what `resolveFilename` gives.
    func testTheDefaultPatternIsUnchangedWithoutACollision() {
        let pattern = "IMG_{ymd}_{hms}_{seq}.{ext}"
        for exts in [["CR2"], ["CR3"], ["JPG"], ["CR2", "JPG"]] as [[String?]] {
            let n = names(pattern, start: 5, exts: exts, folder: ["IMG_20260523_143507_0004.CR2"])
            XCTAssertEqual(n.names, exts.map {
                CameraCapture.resolveFilename(pattern: pattern, timestamp: date, sequence: 5,
                                              cameraExtension: $0)
            })
            XCTAssertEqual(n.sequence, 5)
        }
        XCTAssertEqual(names(pattern, start: 5, exts: ["CR2"], folder: []).names,
                       ["IMG_20260523_143507_0005.CR2"])
    }

    func testTwoFilesWithOneExtensionStayApart() {
        let n = names("Roll_{seq}.{ext}", start: 1, exts: ["JPG", "JPG"], folder: [])
        XCTAssertEqual(n.names, ["Roll_0001.JPG", "Roll_0001_2.JPG"])
    }
}
