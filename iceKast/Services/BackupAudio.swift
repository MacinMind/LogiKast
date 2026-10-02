import Foundation

/// Backup audio files: played in a loop (by Icecast) when a mount's encoder drops off.
/// Files live inside Icecast's web root so the server can stream them, and they are copied
/// in so the original can be moved or deleted.
enum BackupAudio {
    enum Kind: Equatable {
        case mp3, aac
        var label: String { self == .mp3 ? "MP3" : "AAC" }
        var fileExtension: String { self == .mp3 ? "mp3" : "aac" }
    }

    enum BackupError: LocalizedError, Equatable {
        case unreadable
        case tooLarge
        case mp4Container
        case unsupported

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be read."
            case .tooLarge: "That file is larger than 200 MB. Use a shorter backup loop."
            case .mp4Container: "M4A / MP4 files can't be streamed directly. Export the audio as MP3, or as AAC (ADTS), and choose that file."
            case .unsupported: "Use an MP3 or AAC (ADTS) audio file. Other formats can't be streamed by the server."
            }
        }
    }

    static let maxBytes = 200 * 1024 * 1024

    /// Identify MP3 vs raw AAC (ADTS) from the first bytes. Nil if neither.
    static func sniff(_ head: Data) -> Kind? {
        let b = [UInt8](head.prefix(16))
        guard b.count >= 3 else { return nil }
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return .mp3 }                  // "ID3" tag
        guard b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 else { return nil }  // frame sync
        let layer = (b[1] >> 1) & 0x03
        if layer == 0 { return (b[1] & 0xF6) == 0xF0 ? .aac : nil }                  // ADTS: layer bits are 00
        return .mp3
    }

    static func isMP4(_ head: Data) -> Bool {
        let b = [UInt8](head.prefix(12))
        return b.count >= 8 && b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70   // "ftyp"
    }

    static func slug(_ mountName: String) -> String {
        let s = mountName.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        let joined = String(s).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "mount" : joined
    }

    static func storedName(forMount name: String, kind: Kind) -> String {
        "\(slug(name))-backup.\(kind.fileExtension)"
    }

    struct Installed: Equatable {
        var storedName: String
        var displayName: String
        var kind: Kind
        var bytes: Int
    }

    /// Validates and copies `source` into the backup folder for `mountName`.
    static func install(from source: URL, mountName: String, into dir: URL = AppPaths.backupDir) throws -> Installed {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: source.path),
              let size = attrs[.size] as? Int,
              let handle = try? FileHandle(forReadingFrom: source) else { throw BackupError.unreadable }
        defer { try? handle.close() }
        guard size <= maxBytes else { throw BackupError.tooLarge }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        if isMP4(head) { throw BackupError.mp4Container }
        guard let kind = sniff(head) else { throw BackupError.unsupported }

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stored = storedName(forMount: mountName, kind: kind)
        let dest = dir.appendingPathComponent(stored)
        // Clear any earlier backup for this mount (either format).
        for k in [Kind.mp3, .aac] { try? fm.removeItem(at: dir.appendingPathComponent(storedName(forMount: mountName, kind: k))) }
        try fm.copyItem(at: source, to: dest)
        return Installed(storedName: stored, displayName: source.lastPathComponent, kind: kind, bytes: size)
    }

    static func remove(_ storedName: String, from dir: URL = AppPaths.backupDir) {
        guard !storedName.isEmpty, !storedName.contains("/") else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(storedName))
    }

    static func exists(_ storedName: String, in dir: URL = AppPaths.backupDir) -> Bool {
        !storedName.isEmpty && FileManager.default.fileExists(atPath: dir.appendingPathComponent(storedName).path)
    }

    static func kind(ofStored name: String) -> Kind? {
        name.hasSuffix(".mp3") ? .mp3 : (name.hasSuffix(".aac") ? .aac : nil)
    }
}
