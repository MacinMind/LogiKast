import Foundation

struct ConfigIssue: Identifiable, Equatable {
    enum Severity { case error, warning }
    let id = UUID()
    var severity: Severity
    var message: String
    var mountID: UUID?

    static func == (a: ConfigIssue, b: ConfigIssue) -> Bool {
        a.severity == b.severity && a.message == b.message && a.mountID == b.mountID
    }
}

enum ConfigValidator {
    static func issues(for config: AppConfig, backupExists: (String) -> Bool = { BackupAudio.exists($0) }) -> [ConfigIssue] {
        var out: [ConfigIssue] = []
        let s = config.server

        if !(1...65535).contains(s.port) {
            out.append(.init(severity: .error, message: "Port must be between 1 and 65535."))
        } else if s.port < 1024 {
            out.append(.init(severity: .error, message: "Ports below 1024 need administrator rights. Use 1024 or higher (8000 is the Icecast default)."))
        }
        if s.sourcePassword.isEmpty {
            out.append(.init(severity: .error, message: "Source password is empty. Encoders could not connect securely."))
        }
        if s.adminPassword.isEmpty {
            out.append(.init(severity: .error, message: "Admin password is empty."))
        }
        if s.maxClients < 1 { out.append(.init(severity: .error, message: "Max listeners (server) must be at least 1.")) }
        if s.maxSources < 1 { out.append(.init(severity: .error, message: "Max sources must be at least 1.")) }
        if s.maxClients >= 1, s.maxSources >= 1, s.maxClients <= 2 * s.maxSources {
            let eff = s.effectiveLimits
            out.append(.init(severity: .warning, message: "Max listeners (\(s.maxClients)) has to be more than twice Max encoder connections (\(s.maxSources)). The server will use \(eff.sources) encoder connection\(eff.sources == 1 ? "" : "s") instead. Raise max listeners to \(2 * s.maxSources + 1) or more to allow \(s.maxSources)."))
        }
        let streamsNeeded = config.mounts.count + config.mounts.filter { !$0.backupFile.isEmpty }.count      // each backup file also connects like an encoder
        if s.maxClients >= 1, s.maxSources >= 1, s.effectiveLimits.sources < streamsNeeded {
            out.append(.init(severity: .warning, message: "Your limits allow \(s.effectiveLimits.sources) encoder connection\(s.effectiveLimits.sources == 1 ? "" : "s"), but you have \(config.mounts.count) stream\(config.mounts.count == 1 ? "" : "s")\(streamsNeeded > config.mounts.count ? " plus backup audio" : ""). Raise the listener limit so every stream can connect."))
        }
        if s.burstSize < 0 || s.queueSize < 1 {
            out.append(.init(severity: .error, message: "Burst and queue sizes must be positive."))
        }

        if config.mounts.isEmpty {
            out.append(.init(severity: .error, message: "Add at least one mount."))
        }

        var seen = Set<String>()
        for m in config.mounts {
            if !m.name.hasPrefix("/") || m.name.count < 2 {
                out.append(.init(severity: .error, message: "Mount name “\(m.name)” must start with / and have a name, like /live.", mountID: m.id))
            } else if m.name.contains(where: { $0.isWhitespace || "<>&?#\"'".contains($0) }) {
                out.append(.init(severity: .error, message: "Mount name “\(m.name)” can't contain spaces or special characters.", mountID: m.id))
            }
            if !seen.insert(m.name.lowercased()).inserted {
                out.append(.init(severity: .error, message: "Mount name “\(m.name)” is used more than once.", mountID: m.id))
            }
            if m.maxListeners < 0 { out.append(.init(severity: .error, message: "Max listeners can't be negative for \(m.name).", mountID: m.id)) }
            if m.burstSize < 0 { out.append(.init(severity: .error, message: "Burst size can't be negative for \(m.name).", mountID: m.id)) }
            if !m.backupFile.isEmpty, !backupExists(m.backupFile) {
                out.append(.init(severity: .warning, message: "The backup audio file for \(m.name) is missing. Choose it again so listeners hear something when the encoder drops off.", mountID: m.id))
            }
            if m.backupFile.isEmpty, !m.fallbackMount.isEmpty {
                if m.fallbackMount == m.name {
                    out.append(.init(severity: .error, message: "\(m.name) can't fall back to itself.", mountID: m.id))
                } else if !config.mounts.contains(where: { $0.name == m.fallbackMount }) {
                    out.append(.init(severity: .warning, message: "Fallback mount \(m.fallbackMount) for \(m.name) isn't one of your mounts.", mountID: m.id))
                }
            }
            if m.maxListeners > s.maxClients {
                out.append(.init(severity: .warning, message: "\(m.name): max listeners is higher than the server-wide limit (\(s.maxClients)), so the server limit applies.", mountID: m.id))
            }
        }
        for m in config.mounts where m.isPublic {
            for problem in DirectoryListing.problems(for: config) {
                out.append(.init(severity: .warning, message: "\(m.name): \(problem)", mountID: m.id))
            }
        }
        return out
    }

    static func hasErrors(_ config: AppConfig) -> Bool {
        issues(for: config).contains { $0.severity == .error }
    }
}
