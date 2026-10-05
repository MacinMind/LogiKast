import Foundation

/// Audio formats LogiKast can recognize in a live stream. The encoder decides the format;
/// Icecast just passes it through, so this is only used to display what was detected.
enum StreamFormat: String, CaseIterable {
    case mp3, aac, aacPlus

    var label: String {
        switch self {
        case .mp3: "MP3"
        case .aac: "AAC"
        case .aacPlus: "HE-AAC (AAC+)"
        }
    }

    var contentType: String {
        switch self {
        case .mp3: "audio/mpeg"
        case .aac: "audio/aac"
        case .aacPlus: "audio/aacp"
        }
    }

    /// MP3 or AAC family (HE-AAC counts as AAC): a backup file should match the live stream's family.
    var isAAC: Bool { self != .mp3 }

    init?(contentType: String) {
        guard let f = Self.allCases.first(where: { $0.contentType == contentType.lowercased() }) else { return nil }
        self = f
    }
}

enum BadgeTarget: Codable, Hashable {
    case none
    case total
    case mount(UUID)
}

/// Another Icecast (or Shoutcast) server whose stream a mount takes its audio from.
struct RelaySource: Codable, Equatable {
    var server = ""
    var port = 8000
    /// The mount on that server. Shoutcast servers use "/".
    var mount = "/"
    /// Both optional: only needed when the other server asks for a login.
    var username = ""
    var password = ""
    /// When on, the stream is only pulled while someone is listening (saves bandwidth, adds a short start-up delay).
    var onDemand = false

    var isSet: Bool { !server.trimmingCharacters(in: .whitespaces).isEmpty }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8000
        mount = try c.decodeIfPresent(String.self, forKey: .mount) ?? "/"
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        onDemand = try c.decodeIfPresent(Bool.self, forKey: .onDemand) ?? false
    }
}

struct Mount: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "/live"
    var streamName = ""
    var streamDescription = ""
    var genre = ""
    var streamURL = ""
    /// 0 = no per-mount limit (the server-wide client limit still applies).
    var maxListeners = 0
    /// Bytes sent to a new listener immediately on connect, to fill their buffer.
    var burstSize = 65536
    var fallbackMount = ""
    /// When on, listeners moved to the fallback return when the main source comes back.
    var fallbackOverride = true
    var isPublic = false
    /// Empty = use the server's source password.
    var customPassword = ""
    /// Backup audio played in a loop when the encoder drops off (file name inside the backup folder).
    var backupFile = ""
    /// The name of the file the user picked, for display.
    var backupName = ""
    /// True: this mount's audio comes from another server (`relay`) instead of an encoder.
    var isRelay = false
    var relay = RelaySource()
    /// True: when the main source drops off, listeners move to a stream from another server (`backupRelay`).
    var backupIsRelay = false
    var backupRelay = RelaySource()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "/live"
        streamName = try c.decodeIfPresent(String.self, forKey: .streamName) ?? ""
        streamDescription = try c.decodeIfPresent(String.self, forKey: .streamDescription) ?? ""
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        streamURL = try c.decodeIfPresent(String.self, forKey: .streamURL) ?? ""
        maxListeners = try c.decodeIfPresent(Int.self, forKey: .maxListeners) ?? 0
        burstSize = try c.decodeIfPresent(Int.self, forKey: .burstSize) ?? 65536
        fallbackMount = try c.decodeIfPresent(String.self, forKey: .fallbackMount) ?? ""
        fallbackOverride = try c.decodeIfPresent(Bool.self, forKey: .fallbackOverride) ?? true
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic) ?? false
        customPassword = try c.decodeIfPresent(String.self, forKey: .customPassword) ?? ""
        backupFile = try c.decodeIfPresent(String.self, forKey: .backupFile) ?? ""
        backupName = try c.decodeIfPresent(String.self, forKey: .backupName) ?? ""
        isRelay = try c.decodeIfPresent(Bool.self, forKey: .isRelay) ?? false
        relay = try c.decodeIfPresent(RelaySource.self, forKey: .relay) ?? RelaySource()
        backupIsRelay = try c.decodeIfPresent(Bool.self, forKey: .backupIsRelay) ?? false
        backupRelay = try c.decodeIfPresent(RelaySource.self, forKey: .backupRelay) ?? RelaySource()
    }

    /// Whether a backup relay is in effect (a backup file takes precedence over it).
    var usesBackupRelay: Bool { backupFile.isEmpty && backupIsRelay && backupRelay.isSet }
}

/// Another Icecast server whose mounts this server relays all at once (Icecast calls this server the "slave").
struct MasterRelay: Codable, Equatable {
    var enabled = false
    var server = ""
    var port = 8000
    /// The other server's relay login: the user is "relay" unless it was changed there.
    var username = "relay"
    var password = ""
    /// When on, a mount is only pulled while someone listens to it here (one setting for every relayed mount).
    var onDemand = false

    var isActive: Bool { enabled && !server.trimmingCharacters(in: .whitespaces).isEmpty }

    init() {}

    init(from decoder: Decoder) throws {
        let d = MasterRelay()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? d.server
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? d.password
        onDemand = try c.decodeIfPresent(Bool.self, forKey: .onDemand) ?? d.onDemand
    }

    /// What a running server has to be restarted for: Icecast does not stop relays it already made when this changes.
    var restartKey: String {
        guard isActive else { return "" }
        return "\(server.trimmingCharacters(in: .whitespaces))|\(port)|\(username.isEmpty ? "relay" : username)|\(password)|\(onDemand)"
    }
}

struct ServerSettings: Codable, Equatable {
    /// Public host name or IP that listeners use. Shown in connection info.
    var hostname = "localhost"
    var location = ""
    var adminEmail = ""
    var port = 8000
    /// Empty = listen on all network interfaces.
    var bindAddress = ""
    var maxClients = 100
    var maxSources = 10

    /// Icecast refuses to start unless its listener limit is more than twice its encoder-connection limit
    /// ("Client limit is too small for given source limit"). These are the values actually written to the config:
    /// the listener limit is at least 3, and the encoder limit is lowered if the listener limit can't support it.
    var effectiveLimits: (clients: Int, sources: Int) {
        let clients = max(maxClients, 3)
        return (clients, max(1, min(maxSources, (clients - 1) / 2)))
    }
    var burstSize = 65536
    var queueSize = 524288
    var clientTimeout = 30
    var headerTimeout = 15
    var sourceTimeout = 10
    var sourcePassword = ""
    var adminUser = "admin"
    var adminPassword = ""
    /// Lets another Icecast server relay all of this server's mounts at once (it logs in as "relay" with this password).
    /// Relaying a single mount needs none of this: the other server just listens to the mount.
    var allowRelaying = false
    var relayPassword = ""
    /// Relay every visible mount of another Icecast server.
    var masterRelay = MasterRelay()

    init() {}

    init(from decoder: Decoder) throws {
        let d = ServerSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? d.hostname
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? d.location
        adminEmail = try c.decodeIfPresent(String.self, forKey: .adminEmail) ?? d.adminEmail
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? d.bindAddress
        maxClients = try c.decodeIfPresent(Int.self, forKey: .maxClients) ?? d.maxClients
        maxSources = try c.decodeIfPresent(Int.self, forKey: .maxSources) ?? d.maxSources
        burstSize = try c.decodeIfPresent(Int.self, forKey: .burstSize) ?? d.burstSize
        queueSize = try c.decodeIfPresent(Int.self, forKey: .queueSize) ?? d.queueSize
        clientTimeout = try c.decodeIfPresent(Int.self, forKey: .clientTimeout) ?? d.clientTimeout
        headerTimeout = try c.decodeIfPresent(Int.self, forKey: .headerTimeout) ?? d.headerTimeout
        sourceTimeout = try c.decodeIfPresent(Int.self, forKey: .sourceTimeout) ?? d.sourceTimeout
        sourcePassword = try c.decodeIfPresent(String.self, forKey: .sourcePassword) ?? d.sourcePassword
        adminUser = try c.decodeIfPresent(String.self, forKey: .adminUser) ?? d.adminUser
        adminPassword = try c.decodeIfPresent(String.self, forKey: .adminPassword) ?? d.adminPassword
        allowRelaying = try c.decodeIfPresent(Bool.self, forKey: .allowRelaying) ?? d.allowRelaying
        relayPassword = try c.decodeIfPresent(String.self, forKey: .relayPassword) ?? d.relayPassword
        masterRelay = try c.decodeIfPresent(MasterRelay.self, forKey: .masterRelay) ?? d.masterRelay
    }
}

struct NotificationSettings: Codable, Equatable {
    var enabled = true
    var encoderEvents = true
    var serverProblems = true
    var listenerLimit = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        encoderEvents = try c.decodeIfPresent(Bool.self, forKey: .encoderEvents) ?? true
        serverProblems = try c.decodeIfPresent(Bool.self, forKey: .serverProblems) ?? true
        listenerLimit = try c.decodeIfPresent(Bool.self, forKey: .listenerLimit) ?? true
    }

    func allows(_ event: AlertEvent) -> Bool {
        guard enabled else { return false }
        switch event.category {
        case .encoder: return encoderEvents
        case .serverProblem: return serverProblems
        case .listenerLimit: return listenerLimit
        }
    }
}

struct AppConfig: Codable, Equatable {
    var server = ServerSettings()
    var mounts: [Mount] = [Mount()]
    var badge = BadgeTarget.total
    var notifications = NotificationSettings()
    /// False on a brand-new install until the setup assistant is finished or skipped.
    var setupCompleted = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decodeIfPresent(ServerSettings.self, forKey: .server) ?? ServerSettings()
        mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts) ?? [Mount()]
        badge = try c.decodeIfPresent(BadgeTarget.self, forKey: .badge) ?? .total
        notifications = try c.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        setupCompleted = try c.decodeIfPresent(Bool.self, forKey: .setupCompleted) ?? true   // configs from before the wizard existed
    }

    /// A fresh config with random passwords so a new install is secure by default.
    static func makeDefault() -> AppConfig {
        var c = AppConfig()
        c.server.sourcePassword = Password.random()
        c.server.adminPassword = Password.random()
        c.setupCompleted = false
        return c
    }
}

enum Password {
    static func random(length: Int = 12) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
