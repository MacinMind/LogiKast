import Foundation

/// The background server that the app started while it was still called iceKast. It keeps running under the old
/// name until it is stopped, and would hold the same port as the new LogiKast server.
enum LegacyServer {
    static let label = "com.macinmind.icekast.server"
    private static var domain: String { "gui/\(getuid())" }

    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// True while the old iceKast server job is loaded for this user.
    static var isLoaded: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && launchctl(["print", "\(domain)/\(label)"]) == 0
    }

    /// Stops the old server and unloads its job. (The old app's Login Items entry stays until the old app is deleted.)
    /// An old server can outlive its job, so anything still running from the old iceKast folder is stopped too:
    /// two Icecasts on one port is exactly what keeps the new server from answering.
    @discardableResult
    static func stop() -> Bool {
        let ok = launchctl(["bootout", "\(domain)/\(label)"]) == 0
        for (flag, pattern) in [("-f", "Application Support/iceKast/icecast.xml"), ("-x", "icekast-feeder")] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-TERM", flag, pattern]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        return ok
    }
}
