import Foundation

/// Talks to Icecast's admin interface on this Mac: listener lists and kicking listeners.
struct AdminClient {
    var port: Int
    var bindAddress: String
    var user: String
    var password: String

    private var base: String {
        let host = (bindAddress.isEmpty || bindAddress == "0.0.0.0") ? "127.0.0.1" : bindAddress
        return "http://\(host):\(port)/admin/"
    }

    private func request(_ command: String, mount: String, extra: [URLQueryItem] = []) -> URLRequest? {
        var comps = URLComponents(string: base + command)
        comps?.queryItems = [URLQueryItem(name: "mount", value: mount)] + extra
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        return URLSession(configuration: c)
    }()

    /// Listeners of one mount, or nil if the server could not be asked (wrong admin password, server down).
    func listeners(mount: String, onBackup: Bool = false) async -> [Listener]? {
        guard let req = request("listclients", mount: mount),
              let (data, resp) = try? await Self.session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        if code == 404 { return [] }          // nothing on that mount right now
        guard code == 200 else { return nil }
        return ListenerParser.parse(data, onBackup: onBackup)
    }

    /// Disconnects one listener. The player may reconnect by itself.
    func kick(id: String, mount: String) async -> Bool {
        guard let req = request("killclient", mount: mount, extra: [URLQueryItem(name: "id", value: id)]),
              let (_, resp) = try? await Self.session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
