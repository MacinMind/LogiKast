import Foundation

/// Rules for the free-text stream info fields. They travel in single-line headers and
/// directory forms, so line breaks are never allowed.
enum StreamInfoText {
    /// Recommended length: short descriptions read best in directories and status pages.
    static let softLimit = 250
    /// Hard stop, far below the point where Icecast would refuse an encoder's connection
    /// (a connection request over 4096 bytes is dropped, about 3,900 characters of description).
    static let hardLimit = 500

    static func clean(_ text: String, limit: Int = hardLimit) -> String {
        let flat = text.filter { !$0.isNewline }
        return flat.count > limit ? String(flat.prefix(limit)) : flat
    }
}
