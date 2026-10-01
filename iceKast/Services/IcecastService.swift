import Foundation
import ServiceManagement
import os

/// Controls Icecast as a per-user launch agent (SMAppService), so the server keeps running
/// when iceKast is closed, restarts if it crashes, and starts at login.
/// "On" means the agent is registered; "Off" means it is not.
@MainActor
final class IcecastService: ObservableObject {
    static let plistName = "com.macinmind.icekast.server.plist"
    static let label = "com.macinmind.icekast.server"

    enum State: Equatable {
        case stopped
        case running
        case needsApproval
        case failed(String)
    }

    @Published private(set) var state = State.stopped
    /// True while the background service is registered (running or about to).
    @Published private(set) var isEnabled = false
    @Published private(set) var logLines: [String] = []
    /// The icecast.xml the running server was last given.
    @Published private(set) var appliedXML: String?

    private let log = Logger(subsystem: "com.macinmind.icekast", category: "service")
    private let service = SMAppService.agent(plistName: IcecastService.plistName)
    private var timer: Timer?
    private var enabledSince: Date?
    private var reachable = false
    private var port = 0
    private var listenKey = ""
    private let startupGrace: TimeInterval = 12

    init() {
        refresh()
        if isEnabled { adoptRunningServer() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Attaching to a server that was started earlier (e.g. before iceKast was reopened): remember
    /// what it is listening on, so later changes are compared against reality.
    private func adoptRunningServer() {
        guard let xml = try? String(contentsOf: AppPaths.icecastXML, encoding: .utf8) else { return }
        appliedXML = xml
        if let l = ListenSettings(xml: xml) {
            port = l.port
            listenKey = l.key
        }
    }

    /// True if applying `config` needs a full restart (port or network interface changed).
    func requiresRestart(for config: AppConfig) -> Bool {
        isEnabled && Self.listenKey(config) != listenKey
    }

    // MARK: Control

    func start(config: AppConfig) {
        log.notice("start requested (enabled=\(self.isEnabled, privacy: .public), args=\(CommandLine.arguments.dropFirst().joined(separator: " "), privacy: .public))")
        if isEnabled {            // already registered: just (re)start it with current settings
            apply(config: config, forceRestart: true)
            return
        }
        guard FileManager.default.isExecutableFile(atPath: AppPaths.icecastExecutable.path) else {
            state = .failed("The bundled Icecast server is missing from the app.")
            return
        }
        if PortCheck.isInUse(port: config.server.port) {
            state = .failed("Port \(config.server.port) is already in use by another app. Choose a different port in Network settings.")
            return
        }
        guard writeConfig(config) else { return }
        do {
            try service.register()
        } catch {
            refresh()
            if service.status == .requiresApproval {
                state = .needsApproval
            } else {
                state = .failed("Could not start the background server: \(error.localizedDescription)")
            }
            return
        }
        port = config.server.port
        listenKey = Self.listenKey(config)
        enabledSince = Date()
        refresh()
    }

    func stop() {
        log.notice("stop requested")
        do { try service.unregister() } catch {
            state = .failed("Could not stop the background server: \(error.localizedDescription)")
        }
        appliedXML = nil
        reachable = false
        refresh()
    }

    /// Mount, limit and password changes are hot-reloaded (SIGHUP) so live streams keep playing.
    /// A port or interface change needs a restart; encoders then have to reconnect.
    /// Returns true if a restart was needed.
    @discardableResult
    func apply(config: AppConfig, forceRestart: Bool = false) -> Bool {
        guard isEnabled else { return false }
        let needsRestart = forceRestart || Self.listenKey(config) != listenKey
        log.notice("apply: restart=\(needsRestart, privacy: .public) port=\(config.server.port, privacy: .public) running=\(self.port, privacy: .public)")
        // Only a *different* port can be taken by someone else; our own port is of course busy.
        if needsRestart, config.server.port != port, PortCheck.isInUse(port: config.server.port) {
            state = .failed("Port \(config.server.port) is already in use by another app. Choose a different port in Network settings.")
            return false
        }
        guard writeConfig(config) else { return false }
        let target = "\(Launchctl.domain)/\(Self.label)"
        if needsRestart {
            Launchctl.run(["kickstart", "-k", target])
            enabledSince = Date()
            reachable = false
            port = config.server.port
            listenKey = Self.listenKey(config)
        } else {
            Launchctl.run(["kill", "HUP", target])
        }
        return needsRestart
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Called by the status poller so we can tell "registered" from "actually answering".
    func reachabilityChanged(_ reachable: Bool) {
        self.reachable = reachable
        refresh()
    }

    // MARK: State

    func refresh() {
        switch service.status {
        case .enabled:
            if !isEnabled { enabledSince = enabledSince ?? Date() }
            isEnabled = true
        case .requiresApproval:
            isEnabled = false
            state = .needsApproval
            return
        default:
            isEnabled = false
            if case .failed = state {} else if state != .needsApproval { state = .stopped }
            if state == .needsApproval { state = .stopped }
        }

        if isEnabled {
            readLog()
            if reachable {
                state = .running
            } else if Date().timeIntervalSince(enabledSince ?? Date()) > startupGrace {
                let hint = logLines.last { $0.contains("EROR") }
                state = .failed(hint.map { "The server isn't responding: \($0)" }
                    ?? "The server isn't responding on port \(port). It may have failed to start, or the port is taken by another app.")
            } else {
                state = .running   // still starting; views show "starting…" until reachable
            }
        } else {
            enabledSince = nil
        }
    }

    // MARK: Helpers

    private func writeConfig(_ config: AppConfig) -> Bool {
        do {
            AppPaths.syncShare()
            try FileManager.default.createDirectory(at: AppPaths.logDir, withIntermediateDirectories: true)
            let xml = ConfigWriter.xml(for: config, paths: AppPaths.icecastPaths)
            try xml.write(to: AppPaths.icecastXML, atomically: true, encoding: .utf8)
            // The config holds passwords: owner-only.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.icecastXML.path)
            appliedXML = xml
            return true
        } catch {
            state = .failed("Could not write the server configuration: \(error.localizedDescription)")
            return false
        }
    }

    private func readLog() {
        guard let h = try? FileHandle(forReadingFrom: AppPaths.errorLog) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 32_768 ? size - 32_768 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let tail = Array(lines.suffix(200))
        if tail != logLines { logLines = tail }
    }

    private static func listenKey(_ c: AppConfig) -> String { "\(c.server.port)|\(c.server.bindAddress)" }
}

/// What a running server is listening on, read from its icecast.xml.
struct ListenSettings: Equatable {
    var port: Int
    var bindAddress: String
    var key: String { "\(port)|\(bindAddress)" }

    init?(xml: String) {
        guard let doc = try? XMLDocument(xmlString: xml),
              let portText = (try? doc.nodes(forXPath: "//listen-socket/port"))?.first?.stringValue,
              let port = Int(portText.trimmingCharacters(in: .whitespaces)) else { return nil }
        self.port = port
        bindAddress = (try? doc.nodes(forXPath: "//listen-socket/bind-address"))?.first?.stringValue ?? ""
    }
}

enum Launchctl {
    static var domain: String { "gui/\(getuid())" }

    @discardableResult
    static func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
