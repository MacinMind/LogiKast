import Foundation

/// One connected listener, as reported by Icecast's admin listclients.
struct Listener: Identifiable, Equatable {
    var id: String
    var ip: String
    var userAgent: String
    var connectedSeconds: Int
    /// True when this listener is hearing the backup audio rather than the live stream.
    var onBackup = false

    /// "iTunes/12.1" style user agents are shown as-is; empty ones are labelled.
    var player: String { userAgent.isEmpty ? "Unknown player" : userAgent }

    var connectedText: String {
        let s = max(0, connectedSeconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

enum ListenerParser {
    /// Parses `/admin/listclients?mount=…`. Icecast 2.5 spells the element names either way
    /// (IP / ip, UserAgent / useragent, …) depending on the response mode, so both are accepted.
    static func parse(_ data: Data, onBackup: Bool = false) -> [Listener] {
        guard let doc = try? XMLDocument(data: data),
              let nodes = try? doc.nodes(forXPath: "//listener") else { return [] }
        return nodes.compactMap { node -> Listener? in
            guard let el = node as? XMLElement else { return nil }
            func text(_ names: String...) -> String {
                for n in names {
                    if let v = el.elements(forName: n).first?.stringValue { return v.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                return ""
            }
            let id = text("ID", "id")
            guard !id.isEmpty else { return nil }
            return Listener(id: id, ip: text("IP", "ip"), userAgent: text("UserAgent", "useragent"),
                            connectedSeconds: Int(text("Connected", "connected")) ?? 0, onBackup: onBackup)
        }
    }
}

/// Where the web admin lives, for the "Open Web Admin" button. Never contains credentials.
enum WebAdmin {
    static func url(port: Int, bindAddress: String) -> URL? {
        let host = (bindAddress.isEmpty || bindAddress == "0.0.0.0") ? "localhost" : bindAddress
        return URL(string: "http://\(host):\(port)/admin/stats.xsl")
    }
}
