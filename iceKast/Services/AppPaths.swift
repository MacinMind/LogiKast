import Foundation

enum AppPaths {
    static var supportDir: URL {
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
    /// Bundled Icecast web/admin assets.
    static var icecastShare: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/icecast-share", isDirectory: true)
    }

    static var icecastPaths: IcecastPaths {
        IcecastPaths(
            logDir: logDir.path,
            webRoot: icecastShare.appendingPathComponent("web").path,
            adminRoot: icecastShare.appendingPathComponent("admin").path,
            baseDir: supportDir.path)
    }
}
