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
                         name: "iceKast backup for \(m.name)")
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
