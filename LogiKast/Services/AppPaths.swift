import Foundation

enum AppPaths {
    static var supportDir: URL {
        // Unit tests run inside the real app; keep them away from the user's actual settings.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("LogiKast-tests", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LogiKast", isDirectory: true)
    }
    /// Where this app was called iceKast: settings and backup audio are copied from here on first launch.
    static var legacySupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iceKast", isDirectory: true)
    }

    /// First launch after the iceKast → LogiKast rename: copies settings and backup audio into the new folder.
    /// Copies, never moves: a server still running under the old app keeps reading its own folder.
    @discardableResult
    static func migrateLegacySupport(from old: URL? = nil, to new: URL? = nil) -> Bool {
        let fm = FileManager.default
        // Tests run inside the real app: never copy the user's real settings into the test folder.
        if old == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        let old = old ?? legacySupportDir, new = new ?? supportDir
        guard !fm.fileExists(atPath: new.appendingPathComponent("config.json").path),
              fm.fileExists(atPath: old.appendingPathComponent("config.json").path) else { return false }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        guard (try? fm.copyItem(at: old.appendingPathComponent("config.json"), to: new.appendingPathComponent("config.json"))) != nil else { return false }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: new.appendingPathComponent("config.json").path)
        let backup = old.appendingPathComponent("backup", isDirectory: true)
        if fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: backup, to: new.appendingPathComponent("backup", isDirectory: true)) }
        return true
    }

    static var configJSON: URL { supportDir.appendingPathComponent("config.json") }
    static var icecastXML: URL { supportDir.appendingPathComponent("icecast.xml") }
    static var logDir: URL { supportDir.appendingPathComponent("logs", isDirectory: true) }

    /// Bundled Icecast executable (Contents/Helpers/icecast).
    static var icecastExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/icecast")
    }
    /// Icecast web/admin assets as shipped inside the app.
    static var bundledShare: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/icecast-share", isDirectory: true)
    }
    /// Working copy of the assets. The background server reads these, so they must live at a
    /// path that doesn't change when the app is moved or updated.
    static var icecastShare: URL { supportDir.appendingPathComponent("share", isDirectory: true) }
    /// The user's backup audio files (streamed by the background feeder, not served to the public).
    static var backupDir: URL { supportDir.appendingPathComponent("backup", isDirectory: true) }
    /// What the feeder should stream (written by the app) and what it reports back.
    static var backupFeedsFile: URL { supportDir.appendingPathComponent("backup-feeds.json") }
    static var backupStatusFile: URL { supportDir.appendingPathComponent("backup-status.json") }
    /// Where backup files lived in the first version (inside Icecast's web root).
    static var legacyBackupDir: URL { icecastShare.appendingPathComponent("web/backup", isDirectory: true) }

    /// Moves backup files from the old location into the new private folder.
    static func migrateBackupFiles() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: legacyBackupDir.path), !names.isEmpty else { return }
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        for n in names where !n.hasPrefix(".") {
            let dest = backupDir.appendingPathComponent(n)
            if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: legacyBackupDir.appendingPathComponent(n), to: dest) }
        }
        try? fm.removeItem(at: legacyBackupDir)
    }
    static var errorLog: URL { logDir.appendingPathComponent("error.log") }

    /// Copies the bundled assets into Application Support if the app build changed.
    static func syncShare() {
        let fm = FileManager.default
        let stampFile = icecastShare.appendingPathComponent(".stamp")
        let attrs = try? fm.attributesOfItem(atPath: icecastExecutable.path)
        let stamp = "\((attrs?[.size] as? Int) ?? 0)-\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp,
           fm.fileExists(atPath: icecastShare.appendingPathComponent("web").path) { return }
        try? fm.removeItem(at: icecastShare)
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fm.copyItem(at: bundledShare, to: icecastShare)
        try? stamp.write(to: stampFile, atomically: true, encoding: .utf8)
    }

    static var icecastPaths: IcecastPaths {
        IcecastPaths(
            logDir: logDir.path,
            webRoot: icecastShare.appendingPathComponent("web").path,
            adminRoot: icecastShare.appendingPathComponent("admin").path,
            baseDir: supportDir.path)
    }
}
