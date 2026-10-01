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
        x.line("clients", s.maxClients)
        x.line("sources", s.maxSources)
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
        x.close("authentication")

        x.open("listen-socket")
        x.line("port", s.port)
        if !s.bindAddress.isEmpty { x.line("bind-address", s.bindAddress) }
        x.close("listen-socket")

        x.line("fileserve", 1)

        for m in config.mounts {
            x.open("mount", attributes: [("type", "normal")])
            x.line("mount-name", m.name)
            if !m.customPassword.isEmpty {
                x.line("username", "source")
                x.line("password", m.customPassword)
            }
            if m.maxListeners > 0 { x.line("max-listeners", m.maxListeners) }
            x.line("burst-size", m.burstSize)
            if !m.fallbackMount.isEmpty {
                x.line("fallback-mount", m.fallbackMount)
                x.line("fallback-override", m.fallbackOverride ? 1 : 0)
            }
            x.line("type", m.format.contentType)
            x.line("charset", "UTF-8")
            x.line("public", m.isPublic ? 1 : 0)
            if !m.streamName.isEmpty { x.line("stream-name", m.streamName) }
            if !m.streamDescription.isEmpty { x.line("stream-description", m.streamDescription) }
            if !m.genre.isEmpty { x.line("genre", m.genre) }
            if !m.streamURL.isEmpty { x.line("stream-url", m.streamURL) }
            x.close("mount")
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
