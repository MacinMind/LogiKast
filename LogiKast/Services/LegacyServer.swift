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
    @discardableResult
    static func stop() -> Bool { launchctl(["bootout", "\(domain)/\(label)"]) == 0 }
}
