import Foundation

enum AppPaths {
    static var supportDir: URL {
        // Unit tests run inside the real app; keep them away from the user's actual settings.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("iceKast-tests", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("iceKast", isDirectory: true)
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
