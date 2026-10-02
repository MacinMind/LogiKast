import Foundation

struct MountStatus: Identifiable, Equatable {
    var path: String
    var listeners: Int
    var peak: Int
    var title: String?
    var streamName: String?
    var genre: String?
    var streamURL: String?
    var streamDescription: String?
    var contentType: String?
    var bitrate: Int?
    var streamStart: Date?
    var id: String { path }
}

struct ServerStatus: Equatable {
    var serverID: String?
    var serverStart: Date?
    var mounts: [MountStatus]
    /// Internal backup-audio mounts (hidden from the mount list). Listeners on them are real
    /// listeners who are hearing the backup while the encoder is away.
    var backupMounts: [MountStatus] = []

    var totalListeners: Int { mounts.reduce(0) { $0 + $1.listeners } + backupMounts.reduce(0) { $0 + $1.listeners } }

    /// How many listeners are hearing the backup audio of the mount called `name` right now.
    func backupListeners(forMount name: String) -> Int {
        let internal_ = BackupAudio.internalMount(forMount: name)
        return backupMounts.first { $0.path == internal_ }?.listeners ?? 0
    }

    func mount(_ path: String) -> MountStatus? { mounts.first { $0.path == path } }
}

enum StatusParser {
    /// Parses Icecast's /status-json.xsl. Icecast emits `source` as an object for one
    /// mount, an array for several, and omits it when nothing is connected.
    static func parse(_ data: Data) -> ServerStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = root["icestats"] as? [String: Any] else { return nil }

        var sources: [[String: Any]] = []
        if let one = stats["source"] as? [String: Any] {
            sources = [one]
        } else if let many = stats["source"] as? [[String: Any]] {
            sources = many
        }

        let mounts: [MountStatus] = sources.compactMap { src in
            // When a mount has a fallback configured, Icecast keeps listing it after its encoder is gone,
            // as a bare entry with just a listener count. A connected source always has stream details.
            guard src["stream_start_iso8601"] != nil || src["server_type"] != nil || src["content-type"] != nil else { return nil }
            guard let listenURL = src["listenurl"] as? String,
                  let path = URL(string: listenURL)?.path, !path.isEmpty else { return nil }
            return MountStatus(
                path: path,
                listeners: int(src["listeners"]) ?? 0,
                peak: int(src["listener_peak"]) ?? 0,
                title: (src["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                streamName: nonEmpty(src["server_name"], ignoring: ["Unspecified name"]),
                genre: nonEmpty(src["genre"], ignoring: ["various"]),
                streamURL: nonEmpty(src["server_url"]),
                streamDescription: nonEmpty(src["server_description"], ignoring: ["Unspecified description"]),
                contentType: (src["server_type"] as? String) ?? (src["content-type"] as? String),
                bitrate: int(src["bitrate"]) ?? int(src["ice-bitrate"]),
                streamStart: (src["stream_start_iso8601"] as? String).flatMap(date)
            )
        }
        return ServerStatus(
            serverID: stats["server_id"] as? String,
            serverStart: (stats["server_start_iso8601"] as? String).flatMap(date),
            mounts: mounts.filter { !BackupAudio.isInternalMount($0.path) }.sorted { $0.path < $1.path },
            backupMounts: mounts.filter { BackupAudio.isInternalMount($0.path) }.sorted { $0.path < $1.path })
    }

    /// Trimmed string value, or nil if empty or one of Icecast's placeholder defaults.
    private static func nonEmpty(_ v: Any?, ignoring placeholders: [String] = []) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, !placeholders.contains(s) else { return nil }
        return s
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mmZ"
        if let d = f.date(from: s) { return d }
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f.date(from: s)
    }
}


/// Icecast's authenticated /admin/stats.xml lists every source, including hidden ones such as the
/// internal backup-audio mounts, which the public status leaves out.
enum AdminStats {
    static func backupMounts(from data: Data) -> [MountStatus] {
        guard let doc = try? XMLDocument(data: data),
              let nodes = try? doc.nodes(forXPath: "/icestats/source") else { return [] }
        return nodes.compactMap { node -> MountStatus? in
            guard let el = node as? XMLElement, let mount = el.attribute(forName: "mount")?.stringValue,
                  BackupAudio.isInternalMount(mount) else { return nil }
            let listeners = Int((try? el.nodes(forXPath: "listeners").first?.stringValue) ?? "") ?? 0
            return MountStatus(path: mount, listeners: listeners, peak: listeners)
        }.sorted { $0.path < $1.path }
    }

    /// Byte counters of every mount (hidden backup mounts included), for the bandwidth meter.
    static func byteCounters(from data: Data) -> [String: ByteCounters] {
        guard let doc = try? XMLDocument(data: data),
              let nodes = try? doc.nodes(forXPath: "/icestats/source") else { return [:] }
        var out: [String: ByteCounters] = [:]
        for node in nodes {
            guard let el = node as? XMLElement, let mount = el.attribute(forName: "mount")?.stringValue else { continue }
            func number(_ name: String) -> UInt64? { el.elements(forName: name).first?.stringValue.flatMap { UInt64($0) } }
            guard let sent = number("total_bytes_sent") else { continue }
            out[mount] = ByteCounters(sent: sent, read: number("total_bytes_read") ?? 0)
        }
        return out
    }
}
