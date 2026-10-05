import Foundation

/// Builds the instructions for the background feeder from the app's configuration.
enum BackupFeeds {
    static func make(for config: AppConfig, backupDir: URL = AppPaths.backupDir,
                     fileExists: (String) -> Bool = { BackupAudio.exists($0) }) -> BackupFeedsFile {
        let bind = config.server.bindAddress
        let host = (bind.isEmpty || bind == "0.0.0.0") ? "127.0.0.1" : bind
        let feeds: [BackupFeedsFile.Feed] = config.mounts.compactMap { m in
            guard !m.backupFile.isEmpty, fileExists(m.backupFile), let kind = BackupAudio.kind(ofStored: m.backupFile) else { return nil }
            return .init(mount: BackupAudio.internalMount(forMount: m.name),
                         file: backupDir.appendingPathComponent(m.backupFile).path,
                         contentType: kind == .mp3 ? "audio/mpeg" : "audio/aac",
                         name: "LogiKast backup for \(m.name)")
        }
        return BackupFeedsFile(host: host, port: config.server.port, password: config.server.sourcePassword, feeds: feeds)
    }

    /// Writes the feeds file (owner-only: it contains the encoder password).
    static func write(_ feeds: BackupFeedsFile, to url: URL = AppPaths.backupFeedsFile) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(feeds)
        // Keep the file's timestamp unchanged when nothing changed, so the feeder doesn't reconnect.
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func readStatus(from url: URL = AppPaths.backupStatusFile) -> BackupFeederStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BackupFeederStatus.self, from: data)
    }
}

/// What the Backup tab tells the user about a mount's backup audio.
enum BackupState: Equatable {
    case notSet
    case serverOff
    case notRunning                   // server is on but the helper isn't (needs a restart once)
    case notApplied                   // helper is running but doesn't have this mount yet
    case starting
    case ready
    case problem(String)

    static func of(mount: Mount, serverOn: Bool, status: BackupFeederStatus?, now: Date = Date()) -> BackupState {
        guard !mount.backupFile.isEmpty else { return .notSet }
        guard serverOn else { return .serverOff }
        guard let status, status.isFresh(now: now) else { return .notRunning }
        guard let feed = status.feeds.first(where: { $0.mount == BackupAudio.internalMount(forMount: mount.name) }) else { return .notApplied }
        switch feed.state {
        case "streaming": return .ready
        case "error": return .problem(feed.detail)
        default: return .starting
        }
    }
}

/// Relays set to "only pull the stream while someone is listening".
enum RelayDemand {
    /// Icecast applies that setting only when a relay starts, so a relay that was already connected keeps running when
    /// the switch is turned on. These are the connected relays (mount, or a backup's internal mount) that nobody is
    /// listening to: dropping them makes the switch take effect now. They reconnect by themselves when a listener arrives.
    static func idleOnDemandMounts(config: AppConfig, status: ServerStatus?) -> [String] {
        guard let status else { return [] }
        var out: [String] = []
        for m in config.mounts {
            if m.isRelay, m.relay.isSet, m.relay.onDemand, let s = status.mount(m.name), s.listeners == 0 {
                out.append(m.name)
            }
            if m.usesBackupRelay, m.backupRelay.onDemand {
                let path = BackupAudio.internalMount(forMount: m.name)
                if let b = status.backupMounts.first(where: { $0.path == path }), b.listeners == 0 { out.append(path) }
            }
        }
        return out
    }
}

/// Remembers how long each connected on-demand relay has had nobody listening, so one is dropped only after a grace period
/// (a listener who has just arrived triggers the relay to connect, and is counted a moment later).
struct IdleRelayTracker {
    var grace: TimeInterval = 20
    private var since: [String: Date] = [:]

    /// `idle` is every connected on-demand relay with no listeners right now. Returns the ones that have been idle for the
    /// whole grace period; each is reported once, then starts counting again if it is still connected.
    mutating func update(idle: [String], now: Date) -> [String] {
        since = since.filter { idle.contains($0.key) }
        var due: [String] = []
        for path in idle {
            let start = since[path] ?? now
            if now.timeIntervalSince(start) >= grace {
                due.append(path)
                since[path] = nil
            } else {
                since[path] = start
            }
        }
        return due
    }
}
