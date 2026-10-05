import Foundation

struct IcecastPaths {
    var logDir: String
    var webRoot: String
    var adminRoot: String
    var baseDir: String
}

enum ConfigWriter {
    static func xml(for config: AppConfig, paths: IcecastPaths) -> String {
        let s = config.server
        var x = XMLBuilder()
        x.open("icecast")
        x.line("hostname", s.hostname)
        x.line("location", s.location.isEmpty ? "Earth" : s.location)
        x.line("admin", s.adminEmail.isEmpty ? "icemaster@localhost" : s.adminEmail)

        x.open("limits")
        let limits = s.effectiveLimits
        x.line("clients", limits.clients)
        x.line("sources", limits.sources)
        x.line("queue-size", s.queueSize)
        x.line("client-timeout", s.clientTimeout)
        x.line("header-timeout", s.headerTimeout)
        x.line("source-timeout", s.sourceTimeout)
        x.line("burst-size", s.burstSize)
        x.close("limits")

        x.open("authentication")
        x.line("source-password", s.sourcePassword)
        x.line("admin-user", s.adminUser)
        x.line("admin-password", s.adminPassword)
        // Lets another Icecast server relay every visible mount at once; it logs in as "relay". (Relaying one mount
        // needs no password: that server simply listens to the mount.)
        if s.allowRelaying, !s.relayPassword.isEmpty { x.line("relay-password", s.relayPassword) }
        x.close("authentication")

        // Relaying all of another server's mounts: Icecast relays each one it lists, under the same name.
        let master = s.masterRelay
        if master.isActive {
            x.line("master-server", master.server.trimmingCharacters(in: .whitespaces))
            x.line("master-server-port", master.port)
            x.line("master-username", master.username.isEmpty ? "relay" : master.username)
            x.line("master-password", master.password)
            x.line("relays-on-demand", master.onDemand ? 1 : 0)
        }
        // How often the other server is asked for new mounts, and how soon a relay that lost its source is retried
        // (Icecast's default is two minutes).
        if master.isActive || config.mounts.contains(where: { ($0.isRelay && $0.relay.isSet) || $0.usesBackupRelay }) {
            x.line("master-update-interval", 15)
        }

        x.open("listen-socket")
        x.line("port", s.port)
        if !s.bindAddress.isEmpty { x.line("bind-address", s.bindAddress) }
        x.close("listen-socket")

        x.line("fileserve", 1)

        // Public directory: only when a mount is listed AND there's a real contact email
        // (Icecast disables listing otherwise).
        if DirectoryListing.isActive(config) {
            // Icecast 2.5 format; the older <directory> block is deprecated.
            x.open("yp-directory", attributes: [("url", DirectoryListing.ypURL)])
            x.empty("option", attributes: [("name", "timeout"), ("value", String(DirectoryListing.timeoutSeconds))])
            x.close("yp-directory")
        }

        for m in config.mounts {
            x.open("mount", attributes: [("type", "normal")])
            x.line("mount-name", m.name)
            if !m.isRelay, !m.customPassword.isEmpty {
                x.line("username", "source")
                x.line("password", m.customPassword)
            }
            if m.maxListeners > 0 { x.line("max-listeners", m.maxListeners) }
            x.line("burst-size", m.burstSize)
            // Backup audio (streamed in real time by the feeder to an internal mount) takes precedence
            // over a fallback mount.
            let usesInternalBackup = !m.backupFile.isEmpty || m.usesBackupRelay
            let fallback = usesInternalBackup ? BackupAudio.internalMount(forMount: m.name) : m.fallbackMount
            if !fallback.isEmpty {
                x.line("fallback-mount", fallback)
                x.line("fallback-override", (usesInternalBackup ? true : m.fallbackOverride) ? 1 : 0)
            }
            x.line("charset", "UTF-8")
            x.line("public", m.isPublic ? 1 : 0)
            if !m.streamName.isEmpty { x.line("stream-name", StreamInfoText.clean(m.streamName)) }
            if !m.streamDescription.isEmpty { x.line("stream-description", StreamInfoText.clean(m.streamDescription)) }
            if !m.genre.isEmpty { x.line("genre", StreamInfoText.clean(m.genre)) }
            if !m.streamURL.isEmpty { x.line("stream-url", m.streamURL) }
            if m.isRelay, m.relay.isSet { writeRelay(m.relay, into: &x) }     // this mount's audio comes from another server
            x.close("mount")

            if !m.backupFile.isEmpty || m.usesBackupRelay {
                x.open("mount", attributes: [("type", "normal")])
                x.line("mount-name", BackupAudio.internalMount(forMount: m.name))
                x.line("hidden", 1)
                x.line("public", 0)
                x.line("burst-size", 8192)          // small: listeners moved here should be near real time
                if m.backupFile.isEmpty { writeRelay(m.backupRelay, into: &x) }     // a stream from another server, not a file
                x.close("mount")
            }
        }

        x.open("paths")
        x.line("basedir", paths.baseDir)
        x.line("logdir", paths.logDir)
        x.line("webroot", paths.webRoot)
        x.line("adminroot", paths.adminRoot)
        x.empty("alias", attributes: [("source", "/"), ("destination", "/status.xsl")])
        x.close("paths")

        x.open("logging")
        x.line("accesslog", "access.log")
        x.line("errorlog", "error.log")
        x.line("loglevel", 3)
        x.line("logsize", 10000)
        x.close("logging")

        x.close("icecast")
        return x.output
    }

    /// A <relay> block: the mount that contains it takes its audio from this other server.
    private static func writeRelay(_ r: RelaySource, into x: inout XMLBuilder) {
        x.open("relay")
        x.line("server", r.server.trimmingCharacters(in: .whitespaces))
        x.line("port", r.port)
        x.line("mount", r.mount.isEmpty ? "/" : r.mount)
        if !r.username.isEmpty { x.line("username", r.username) }
        if !r.password.isEmpty { x.line("password", r.password) }
        x.line("on-demand", r.onDemand ? 1 : 0)
        x.close("relay")
    }
}

struct XMLBuilder {
    private(set) var output = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    private var depth = 0

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private var indent: String { String(repeating: "  ", count: depth) }

    private func attrs(_ a: [(String, String)]) -> String {
        a.map { " \($0.0)=\"\(Self.escape($0.1))\"" }.joined()
    }

    mutating func open(_ tag: String, attributes: [(String, String)] = []) {
        output += "\(indent)<\(tag)\(attrs(attributes))>\n"
        depth += 1
    }

    mutating func close(_ tag: String) {
        depth -= 1
        output += "\(indent)</\(tag)>\n"
    }

    mutating func empty(_ tag: String, attributes: [(String, String)]) {
        output += "\(indent)<\(tag)\(attrs(attributes))/>\n"
    }

    mutating func line(_ tag: String, _ value: String) {
        output += "\(indent)<\(tag)>\(Self.escape(value))</\(tag)>\n"
    }

    mutating func line(_ tag: String, _ value: Int) {
        line(tag, String(value))
    }
}
