import Foundation

enum StreamFormat: String, Codable, CaseIterable, Identifiable {
    case mp3, aac, aacPlus

    var id: String { rawValue }

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

struct Mount: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "/live"
    var streamName = ""
    var streamDescription = ""
    var genre = ""
    var streamURL = ""
    var format = StreamFormat.mp3
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

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "/live"
        streamName = try c.decodeIfPresent(String.self, forKey: .streamName) ?? ""
        streamDescription = try c.decodeIfPresent(String.self, forKey: .streamDescription) ?? ""
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        streamURL = try c.decodeIfPresent(String.self, forKey: .streamURL) ?? ""
        format = try c.decodeIfPresent(StreamFormat.self, forKey: .format) ?? .mp3
        maxListeners = try c.decodeIfPresent(Int.self, forKey: .maxListeners) ?? 0
        burstSize = try c.decodeIfPresent(Int.self, forKey: .burstSize) ?? 65536
        fallbackMount = try c.decodeIfPresent(String.self, forKey: .fallbackMount) ?? ""
        fallbackOverride = try c.decodeIfPresent(Bool.self, forKey: .fallbackOverride) ?? true
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic) ?? false
        customPassword = try c.decodeIfPresent(String.self, forKey: .customPassword) ?? ""
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
    var burstSize = 65536
    var queueSize = 524288
    var clientTimeout = 30
    var headerTimeout = 15
    var sourceTimeout = 10
    var sourcePassword = ""
    var adminUser = "admin"
    var adminPassword = ""

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
    }
}

struct AppConfig: Codable, Equatable {
    var server = ServerSettings()
    var mounts: [Mount] = [Mount()]
    var badge = BadgeTarget.total

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decodeIfPresent(ServerSettings.self, forKey: .server) ?? ServerSettings()
        mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts) ?? [Mount()]
        badge = try c.decodeIfPresent(BadgeTarget.self, forKey: .badge) ?? .total
    }

    /// A fresh config with random passwords so a new install is secure by default.
    static func makeDefault() -> AppConfig {
        var c = AppConfig()
        c.server.sourcePassword = Password.random()
        c.server.adminPassword = Password.random()
        return c
    }
}

enum Password {
    static func random(length: Int = 12) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
