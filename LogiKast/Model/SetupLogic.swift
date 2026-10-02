import Foundation

enum SetupAudience: String, CaseIterable, Identifiable {
    case thisMac
    case anyone

    var id: String { rawValue }

    /// Icecast bind address: loopback only, or all interfaces (empty).
    var bindAddress: String { self == .thisMac ? "127.0.0.1" : "" }

    init(bindAddress: String) {
        self = bindAddress == "127.0.0.1" ? .thisMac : .anyone
    }
}

enum PortStatus: Equatable {
    case available
    case invalid
    case tooLow
    case inUse
}

/// Pure helpers behind the setup assistant, kept separate so they can be unit tested.
enum SetupLogic {
    static let bitrates = [32, 48, 64, 96, 128, 192, 256, 320]
    static let listenerPresets = [10, 25, 50, 100, 250, 500, 1000]

    /// Upload bandwidth (Mbps) needed to serve `listeners` simultaneous listeners at `kbps` each.
    static func uploadMbps(listeners: Int, kbps: Int) -> Double {
        Double(max(listeners, 0) * max(kbps, 0)) / 1000
    }

    static func describe(mbps: Double) -> String {
        mbps < 10 ? String(format: "%.1f Mbps", mbps) : String(format: "%.0f Mbps", mbps.rounded(.up))
    }

    /// `ownPort` is the port our own running server already uses (so it is not "in use by another app").
    static func status(port: Int, ownPort: Int?, isInUse: (Int) -> Bool) -> PortStatus {
        guard (1...65535).contains(port) else { return .invalid }
        guard port >= 1024 else { return .tooLow }
        if port == ownPort { return .available }
        return isInUse(port) ? .inUse : .available
    }

    /// First free port, starting with the preferred one, then the usual Icecast alternatives.
    static func suggestPort(preferred: Int, ownPort: Int? = nil, isInUse: (Int) -> Bool) -> Int? {
        var seen = Set<Int>()
        let candidates = ([preferred, 8000, 8010, 8080, 8001, 8888, 9000, 9010, 8100, 8200]
            + Array(8300...8320)).filter { seen.insert($0).inserted }
        return candidates.first { status(port: $0, ownPort: ownPort, isInUse: isInUse) == .available }
    }

    /// Makes sure there is at least one mount for the wizard to edit.
    static func ensureMount(_ config: AppConfig) -> AppConfig {
        var c = config
        if c.mounts.isEmpty { c.mounts = [Mount()] }
        return c
    }
}

/// One difference the setup assistant would make to an existing station.
struct SetupChange: Equatable {
    var text: String
    /// True if encoders or listeners are disconnected or must change something.
    var disruptive: Bool
}

extension SetupLogic {
    /// What applying `new` over `old` would change. The assistant only edits the server settings
    /// and the first mount, so only those are compared.
    static func changes(from old: AppConfig, to new: AppConfig) -> [SetupChange] {
        var out: [SetupChange] = []
        func note(_ label: String, _ a: String, _ b: String, disruptive: Bool = false) {
            guard a != b else { return }
            out.append(SetupChange(text: "\(label): \(a.isEmpty ? "(blank)" : a) → \(b.isEmpty ? "(blank)" : b)", disruptive: disruptive))
        }
        let o = old.server, n = new.server
        note("Port", String(o.port), String(n.port), disruptive: true)
        note("Who can listen", o.bindAddress == "127.0.0.1" ? "only this Mac" : "anyone",
             n.bindAddress == "127.0.0.1" ? "only this Mac" : "anyone", disruptive: true)
        note("Station address", o.hostname, n.hostname)
        note("Max listeners", String(o.maxClients), String(n.maxClients))
        if let om = old.mounts.first, let nm = new.mounts.first {
            note("Mount name", om.name, nm.name, disruptive: true)
            note("Station name", om.streamName, nm.streamName)
            note("Description", om.streamDescription, nm.streamDescription)
            note("Genre", om.genre, nm.genre)
            note("Website", om.streamURL, nm.streamURL)
        }
        return out
    }
}
