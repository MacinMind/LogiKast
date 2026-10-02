import Foundation

/// Public directory ("YP") listing. Icecast only advertises a stream when the server config has a
/// <directory> block AND a real contact email; without them it silently disables listing.
enum DirectoryListing {
    /// The Xiph.Org directory, the default directory for Icecast streams.
    static let ypURL = "http://dir.xiph.org/cgi-bin/yp-cgi"
    static let timeoutSeconds = 15

    /// Icecast's placeholder contact; it counts as "not configured".
    static let placeholderEmail = "icemaster@localhost"

    static func isUsableEmail(_ email: String) -> Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e != placeholderEmail, let at = e.firstIndex(of: "@") else { return false }
        let domain = e[e.index(after: at)...]
        return !e[..<at].isEmpty && domain.contains(".") && !domain.hasSuffix(".") && !e.contains(" ")
    }

    /// True for names that only work on this Mac or this local network.
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.isEmpty || h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }        // a domain name: assume public
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    static func anyListed(_ config: AppConfig) -> Bool { config.mounts.contains { $0.isPublic } }

    /// Whether the config will actually make Icecast contact the directory.
    static func isActive(_ config: AppConfig) -> Bool {
        anyListed(config) && isUsableEmail(config.server.adminEmail)
    }

    /// Plain-language reasons a listed mount will not appear in the directory.
    static func problems(for config: AppConfig) -> [String] {
        guard anyListed(config) else { return [] }
        var out: [String] = []
        if !isUsableEmail(config.server.adminEmail) {
            out.append("Add a contact email. The directory requires one, and without it your station is not listed.")
        }
        if config.server.bindAddress == "127.0.0.1" {
            out.append("The server only accepts connections from this Mac, so nobody could reach a listed stream. Set \"Who can listen\" to Anyone in the Setup Assistant, or clear the interface on the Server page.")
        }
        if isPrivateHost(config.server.hostname) {
            out.append("Your station address (\(config.server.hostname.isEmpty ? "blank" : config.server.hostname)) only works on your own network. Enter your public IP address or domain name.")
        }
        return out
    }
}
