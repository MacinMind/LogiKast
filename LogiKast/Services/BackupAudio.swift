import Foundation

/// Backup audio files: played in a loop (by the feeder) when a mount's encoder drops off.
/// They are copied into the app's backup folder so the original can be moved or deleted. Anything that isn't already
/// MP3 or AAC (ADTS) in the live stream's format is converted on the way in (see BackupConverter).
enum BackupAudio {
    enum Kind: Equatable {
        case mp3, aac
        var label: String { self == .mp3 ? "MP3" : "AAC" }
        var fileExtension: String { self == .mp3 ? "mp3" : "aac" }
    }

    enum BackupError: LocalizedError, Equatable {
        case unreadable
        case tooLarge
        case cannotRead
        case cancelled
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be read."
            case .tooLarge: "That file is larger than 200 MB once prepared. Use a shorter backup loop."
            case .cannotRead: "macOS can't read that audio file. It may be copy-protected or in a format macOS doesn't support (such as Ogg). Try MP3, AAC, M4A, WAV, AIFF, FLAC or ALAC."
            case .cancelled: "Conversion canceled."
            case .conversionFailed(let why): "The file couldn't be converted. \(why)"
            }
        }
    }

    /// Largest backup file that is kept (after any conversion).
    static let maxBytes = 200 * 1024 * 1024
    /// Largest file accepted for conversion: an uncompressed WAV is much bigger than the MP3 made from it.
    static let maxSourceBytes = 1024 * 1024 * 1024

    static func rateText(_ hz: Int) -> String {
        let k = Double(hz) / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%g kHz", k)
    }

    /// Internal mount the feeder streams a mount's backup audio to. Hidden from listings.
    static let internalPrefix = "/_backup/"
    static func internalMount(forMount name: String) -> String { internalPrefix + slug(name) }
    static func isInternalMount(_ path: String) -> Bool { path.hasPrefix(internalPrefix)}

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

    /// True when the first bytes are an ADTS header whose sample rate is half of `playbackRate`: the way a live HE-AAC (AAC+)
    /// stream marks itself (44.1 kHz audio is labeled 22.05 kHz, and players find the extra half from the stream itself).
    static func looksHighEfficiency(adtsHead head: Data, playbackRate: Double) -> Bool {
        let b = [UInt8](head.prefix(4))
        guard b.count >= 3, b[0] == 0xFF, (b[1] & 0xF6) == 0xF0 else { return false }
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let index = Int((b[2] >> 2) & 0x0F)
        return index < rates.count && abs(rates[index] * 2 - playbackRate) < 1
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

    static func storedName(forMount name: String, kind: Kind, highEfficiency: Bool = false) -> String {
        "\(slug(name))-backup\(highEfficiency ? "-he" : "").\(kind.fileExtension)"
    }

    /// True for an HE-AAC backup that LogiKast made (its name ends in -he.aac).
    static func isHighEfficiency(_ storedName: String) -> Bool { storedName.hasSuffix("-he.aac") }

    struct Installed: Equatable {
        var storedName: String
        var displayName: String
        var kind: Kind
        var bytes: Int
        /// Set when the file was converted: what it was turned into.
        var convertedTo: BackupTarget? = nil
    }

    /// Validates and copies `source` into the backup folder for `mountName`, converting it first when it isn't already
    /// MP3 or AAC (ADTS) in the `target` format. With no `target` (no live stream to copy), an MP3 or AAC file is kept as it
    /// is, and anything else becomes `BackupTarget.standard`.
    static func install(from source: URL, mountName: String, target: BackupTarget? = nil, into dir: URL = AppPaths.backupDir,
                        cancel: CancelFlag = CancelFlag(), progress: (Double) -> Void = { _ in }) throws -> Installed {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: source.path),
              let size = attrs[.size] as? Int,
              let handle = try? FileHandle(forReadingFrom: source) else { throw BackupError.unreadable }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        try? handle.close()
        guard size <= maxSourceBytes else { throw BackupError.tooLarge }

        let kind = isMP4(head) ? nil : sniff(head)
        if let kind, size <= maxBytes, keepsAsIs(source, kind: kind, head: head, target: target) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let he = kind == .aac && (target?.highEfficiency ?? false)
            let stored = storedName(forMount: mountName, kind: kind, highEfficiency: he)
            let dest = dir.appendingPathComponent(stored)
            clearBackups(forMount: mountName, in: dir)
            try fm.copyItem(at: source, to: dest)
            return Installed(storedName: stored, displayName: source.lastPathComponent, kind: kind, bytes: size)
        }
        return try convert(source, displayName: source.lastPathComponent, mountName: mountName,
                           target: target ?? .standard, into: dir, cancel: cancel, progress: progress)
    }

    /// Converts the backup already stored for `mountName` to `target` (used when the live stream turns out to differ).
    static func reconvert(stored: String, displayName: String, mountName: String, target: BackupTarget, into dir: URL = AppPaths.backupDir,
                          cancel: CancelFlag = CancelFlag(), progress: (Double) -> Void = { _ in }) throws -> Installed {
        try convert(dir.appendingPathComponent(stored), displayName: displayName, mountName: mountName,
                    target: target, into: dir, cancel: cancel, progress: progress)
    }

    private static func keepsAsIs(_ source: URL, kind: Kind, head: Data, target: BackupTarget?) -> Bool {
        guard let target else { return true }
        guard kind == target.kind, let info = BackupConverter.info(of: source) else { return false }
        if kind == .aac, looksHighEfficiency(adtsHead: head, playbackRate: info.sampleRate) != target.highEfficiency { return false }
        return Int(info.sampleRate.rounded()) == target.sampleRate && info.channels == target.channels
    }

    private static func convert(_ source: URL, displayName: String, mountName: String, target: BackupTarget, into dir: URL,
                                cancel: CancelFlag, progress: (Double) -> Void) throws -> Installed {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stored = storedName(forMount: mountName, kind: target.kind, highEfficiency: target.highEfficiency)
        let temp = dir.appendingPathComponent(".converting-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try BackupConverter.convert(from: source, to: temp, target: target, cancel: cancel, progress: progress)
        let bytes = (try? fm.attributesOfItem(atPath: temp.path)[.size] as? Int) ?? 0
        guard bytes > 0 else { throw BackupError.conversionFailed("Nothing was produced.") }
        guard bytes <= maxBytes else { throw BackupError.tooLarge }
        let head = (try? FileHandle(forReadingFrom: temp)).flatMap { h -> Data? in defer { try? h.close() }; return try? h.read(upToCount: 16) } ?? Data()
        guard sniff(head) == target.kind else { throw BackupError.conversionFailed("The result isn't a valid \(target.kind.label) file.") }
        clearBackups(forMount: mountName, in: dir)
        try fm.moveItem(at: temp, to: dir.appendingPathComponent(stored))
        return Installed(storedName: stored, displayName: displayName, kind: target.kind, bytes: bytes, convertedTo: target)
    }

    /// Removes any earlier backup for this mount (either format).
    private static func clearBackups(forMount name: String, in dir: URL) {
        for k in [Kind.mp3, .aac] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(storedName(forMount: name, kind: k))) }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(storedName(forMount: name, kind: .aac, highEfficiency: true)))
    }

    /// "MP3 · 44.1 kHz · stereo · about 128 kbps" for a stored backup file, or nil if it can't be read.
    static func describe(stored: String, in dir: URL = AppPaths.backupDir) -> String? {
        let url = dir.appendingPathComponent(stored)
        guard let kind = kind(ofStored: stored), let info = BackupConverter.info(of: url) else { return nil }
        let he = isHighEfficiency(stored)
        var parts = [he ? "HE-AAC" : kind.label, rateText(Int(info.sampleRate.rounded())), info.channels == 1 ? "mono" : "stereo"]
        if info.seconds > 1, let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int {
            parts.append("about \(Int((Double(bytes) * 8 / info.seconds / 1000).rounded())) kbps")
        }
        return parts.joined(separator: " · ")
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
