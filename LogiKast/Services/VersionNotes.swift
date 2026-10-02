import Foundation

/// The "Version Notes" shown from the Help menu: read from the same appcast feed Sparkle uses.
/// Each appcast item's description is HTML; only the part that starts at "<b>Version" is the notes (the text before it
/// is the "You are subscribed to the beta development releases" message, which isn't wanted here).
enum VersionNotes {
    /// Help menu wording: people on the beta feed see "Beta Version Notes".
    static func menuTitle(includeBetas: Bool) -> String { includeBetas ? "Beta Version Notes" : "Version Notes" }

    /// The notes HTML of every item in the feed, newest first (by build number), or nil if the feed has none.
    static func notes(fromAppcast data: Data) -> [String] {
        guard let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let items = try? doc.nodes(forXPath: "//item") else { return [] }
        var found: [(build: [Int], html: String)] = []
        for case let item as XMLElement in items {
            let description = item.elements(forName: "description").first?.stringValue ?? ""
            guard let notes = Self.notesPart(of: description) else { continue }
            let build = (item.elements(forName: "sparkle:version").first?.stringValue ?? "")
                .split(separator: ".").compactMap { Int($0) }
            found.append((build, notes))
        }
        return found.sorted { $0.build.lexicographicallyPrecedes($1.build) == false && $0.build != $1.build }.map(\.html)
    }

    /// From "<b>Version" to the end, with the stray "</b" typo browsers would otherwise swallow repaired; nil when absent.
    static func notesPart(of description: String) -> String? {
        guard let start = description.range(of: "<b>Version", options: .caseInsensitive) else { return nil }
        var part = String(description[start.lowerBound...])
        part = part.replacingOccurrences(of: #"</b(?![>a-zA-Z])"#, with: "</b>", options: .regularExpression)
        part = part.trimmingCharacters(in: .whitespacesAndNewlines)
        return part.isEmpty ? nil : part
    }

    /// A complete page for the notes window; follows the system's light or dark appearance.
    static func page(for notes: [String]) -> String {
        let body = notes.map { "<div class=\"v\">\($0)</div>" }.joined(separator: "\n")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>
        body { font: 13px -apple-system, BlinkMacSystemFont, sans-serif; margin: 16px 20px; line-height: 1.45; }
        .v { margin-bottom: 18px; } b { font-size: 14px; } ul { margin: 6px 0 0; padding-left: 22px; } li { margin: 3px 0; }
        a { color: -apple-system-blue; }
        </style></head><body>\(body)</body></html>
        """
    }

    static func fetch(includeBetas: Bool) async throws -> [String] {
        guard let url = URL(string: UpdateFeed.url(includeBetas: includeBetas)) else { return [] }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("LogiKast", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return notes(fromAppcast: data)
    }
}
