import Foundation

/// Search, sort, summary and refresh pacing for the listener list, kept apart from the view so it can be tested at scale.
enum ListenerList {
    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Newest first", longest = "Longest connected", address = "Address"
        var id: String { rawValue }
    }

    static func filtered(_ all: [Listener], search: String = "", sort: Sort) -> [Listener] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var out = q.isEmpty ? all : all.filter { $0.ip.lowercased().contains(q) || $0.userAgent.lowercased().contains(q) }
        switch sort {
        case .newest: out.sort { $0.connectedSeconds < $1.connectedSeconds }
        case .longest: out.sort { $0.connectedSeconds > $1.connectedSeconds }
        case .address: out.sort { $0.ip.localizedStandardCompare($1.ip) == .orderedAscending }
        }
        return out
    }

    struct Summary: Equatable {
        var total: Int
        var uniqueAddresses: Int
        var onBackup: Int
        /// The most common players, most common first.
        var topPlayers: [(name: String, count: Int)]

        static func == (a: Summary, b: Summary) -> Bool {
            a.total == b.total && a.uniqueAddresses == b.uniqueAddresses && a.onBackup == b.onBackup
                && a.topPlayers.map(\.name) == b.topPlayers.map(\.name) && a.topPlayers.map(\.count) == b.topPlayers.map(\.count)
        }
    }

    static func summary(_ all: [Listener], topPlayers n: Int = 3) -> Summary {
        var players: [String: Int] = [:]
        for l in all { players[family(of: l.player), default: 0] += 1 }
        let top = players.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map { (name: $0.key, count: $0.value) }
        return Summary(total: all.count, uniqueAddresses: Set(all.map(\.ip)).count,
                       onBackup: all.filter(\.onBackup).count, topPlayers: top)
    }

    /// "VLC/3.0.24 LibVLC/3.0.24" → "VLC": versions would split one app into dozens of rows.
    static func family(of agent: String) -> String {
        let first = agent.split(separator: " ").first.map(String.init) ?? agent
        return first.split(separator: "/").first.map(String.init) ?? "Unknown player"
    }

    /// Seconds between refreshes: quick for a few listeners, slower as the list (and the server's work to build it) grows.
    static func refreshInterval(listenerCount: Int) -> TimeInterval {
        switch listenerCount {
        case ..<200: 3
        case ..<600: 5
        default: 10
        }
    }
}
