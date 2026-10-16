import Foundation
import CryptoKit

/// Reads and writes `<base>.xmp` next to the image (the Adobe convention, image extension
/// dropped).
///
/// Writes are temp-file-then-replace in the same directory (a crash leaves the old file or
/// the new file, never half of one), skipped when none of our fields would change
/// (cloud-synced folders otherwise spawn conflict files), refused for a sidecar value whose
/// version is newer than this package's, and refused when the existing file is not
/// parseable XMP (a corrupt or foreign file is never overwritten blind). Everything in the file outside our
/// namespaces and the standard fields the sidecar carries is preserved. Debouncing lives
/// in the app.
public struct SidecarStore: Sendable {
    public static let ext = "xmp"
    static let tempPrefix = "."
    static let tempMarker = ".xmp.tmp-"

    /// Test hook: called after the temp file is fully written and before it replaces the
    /// target. Throwing here simulates a crash between the two steps.
    public var beforeReplace: (@Sendable () throws -> Void)?

    public init() {}

    public enum SaveResult: Equatable, Sendable { case written, unchanged }

    public enum LoadStatus: Equatable, Sendable {
        /// Sidecar matches the image it sits next to (or carries no fingerprint to check).
        case ok
        /// The image's size or fingerprint differs from the recorded one: state is shown,
        /// never applied silently.
        case sourceChanged
        /// Written by a newer schema version: read-only.
        case readOnly
    }

    public struct Loaded: Sendable {
        public let sidecar: Sidecar
        public let status: LoadStatus
        public var isReadOnly: Bool { status == .readOnly }
    }

    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case readOnly(version: Int)
        public var description: String {
            switch self {
            case .readOnly(let v): return "sidecar was written by a newer schema (version \(v)), so it is not rewritten"
            }
        }
    }

    // MARK: paths

    public static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension(ext)
    }

    /// True for `.xmp` names, so folder scans can skip sidecars.
    public static func isSidecar(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == ext
    }

    static func tempURL(for sidecarURL: URL) -> URL {
        let dir = sidecarURL.deletingLastPathComponent()
        let name = tempPrefix + sidecarURL.lastPathComponent + ".tmp-" + UUID().uuidString
        return dir.appendingPathComponent(name)
    }

    // MARK: source identity

    /// "sha256:<hex>" over the first 64 KB of the file.
    public static func fingerprint(of imageURL: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: imageURL)
        defer { try? h.close() }
        let head = try h.read(upToCount: 65_536) ?? Data()
        let digest = SHA256.hash(data: head)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func source(for imageURL: URL) throws -> SidecarSource {
        let attrs = try FileManager.default.attributesOfItem(atPath: imageURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return SidecarSource(name: imageURL.lastPathComponent, size: size, mtime: mtime,
                             fingerprint: try fingerprint(of: imageURL))
    }

    // MARK: load

    /// Nil when there is no sidecar (an untouched image). A file that is not XMP throws
    /// `XMPError` so the UI can show it.
    public func load(for imageURL: URL) throws -> Loaded? {
        let url = Self.sidecarURL(for: imageURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        Self.sweepStaleTemps(in: url.deletingLastPathComponent())
        let data = try Data(contentsOf: url)
        let live = try Self.source(for: imageURL)
        let packet = try XMPSidecarCodec.parse(data)
        let sc = try XMPSidecarCodec.decode(packet.fields, liveSource: live, strict: false)
        if sc.version > Sidecar.currentVersion { return Loaded(sidecar: sc, status: .readOnly) }
        let recorded = packet.fields[XMPField.sourceFingerprint]
        let status: LoadStatus = (recorded == nil || (live.size == sc.source.size && live.fingerprint == sc.source.fingerprint)) ? .ok : .sourceChanged
        return Loaded(sidecar: sc, status: status)
    }

    // MARK: save

    @discardableResult
    public func save(_ sidecar: Sidecar, for imageURL: URL) throws -> SaveResult {
        if sidecar.version > Sidecar.currentVersion { throw StoreError.readOnly(version: sidecar.version) }
        let url = Self.sidecarURL(for: imageURL)
        let existing = try? Data(contentsOf: url)
        // Merge into the existing packet so foreign content survives. A file that does
        // not parse is an error, never something to overwrite.
        let packet = try existing.map { try XMPSidecarCodec.parse($0) }
        // No-op check on the fields, not the bytes: re-serializing a foreign packet can
        // change whitespace, and that must never count as a change of state.
        if let packet {
            let ours = XMPSidecarCodec.attributes(for: sidecar)
            let theirs = packet.fields.filter {
                XMPSidecarCodec.ownedNamespaces.contains($0.key.ns) || (XMPSidecarCodec.standardKeys.contains($0.key) && ours[$0.key] != nil)
            }
            if ours == theirs { return .unchanged }
        }
        let bytes = try XMPSidecarCodec.encode(sidecar, into: packet?.document ?? XMPSidecarCodec.emptyPacket())

        let tmp = Self.tempURL(for: url)
        try bytes.write(to: tmp, options: [])
        try beforeReplace?()
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        return .written
    }

    public func remove(for imageURL: URL) throws {
        let url = Self.sidecarURL(for: imageURL)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// A temp younger than this may belong to a save still running in another process,
    /// such as the other app writing into the same folder, so the sweep leaves it alone.
    static let staleTempAge: TimeInterval = 60

    /// Deletes every dotfile in `dir` whose name contains `.xmp.tmp-` and that was last
    /// modified at least `staleTempAge` before `now`: a temp left by a crash between write
    /// and replace. Temps are never read.
    static func sweepStaleTemps(in dir: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names where n.hasPrefix(tempPrefix) && n.contains(tempMarker) {
            let url = dir.appendingPathComponent(n)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) >= staleTempAge else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
