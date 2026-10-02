import Foundation
import Network

/// A tiny web proxy on this Mac that lets "Open Web Admin" sign in by itself. Browsers such as Safari ignore a
/// username and password written into an address, so the browser opens this proxy instead; the proxy adds the
/// admin login and passes the page through from Icecast.
///
/// It only listens on this Mac (loopback), on a random port, and only answers a browser that arrived through the
/// one-time link (a random token, remembered in a cookie). Nothing else on the network or Mac can use it.
final class AdminProxy: @unchecked Sendable {
    struct Target { var host: String; var port: Int; var user: String; var password: String }

    private let queue = DispatchQueue(label: "icekast.adminproxy")
    private let lock = NSLock()
    private var target = Target(host: "127.0.0.1", port: 8000, user: "", password: "")
    private var listener: NWListener?
    private var listenPort: UInt16?
    let token = (0..<24).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }.map(String.init).joined()

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Starts the proxy if needed and returns the link to open in the browser.
    func start(target new: Target) async -> URL? {
        lock.lock(); target = new; lock.unlock()
        if listenPort == nil {
            listenPort = await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
                let params = NWParameters.tcp
                params.acceptLocalOnly = true
                params.requiredInterfaceType = .loopback
                guard let l = try? NWListener(using: params, on: .any) else { return cont.resume(returning: nil) }
                var resumed = false
                l.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready: resumed = true; cont.resume(returning: l.port?.rawValue)
                    case .failed, .cancelled: resumed = true; cont.resume(returning: nil)
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                self.listener = l
                l.start(queue: queue)
            }
        }
        guard let port = listenPort else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/__icekast/\(token)")
    }

    func stop() { listener?.cancel(); listener = nil; listenPort = nil }

    // MARK: connections

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 2_000_000 || error != nil { return conn.cancel() }
            if let req = Self.parse(buf) {
                self.handle(req, on: conn)
            } else if done {
                conn.cancel()
            } else {
                self.read(conn, buffer: buf)
            }
        }
    }

    struct Request { var method: String; var path: String; var headers: [String: String]; var body: Data }

    /// Parses one complete HTTP request, or returns nil if more bytes are needed.
    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: first[0], path: first[1], headers: headers, body: Data(body.prefix(length)))
    }

    private func handle(_ req: Request, on conn: NWConnection) {
        // One-time link: remember the token in a cookie, then go to the admin start page.
        if req.path == "/__icekast/\(token)" {
            return send(conn, status: 302, reason: "Found",
                        headers: ["Location": "/admin/stats.xsl", "Set-Cookie": "icekast=\(token); Path=/; HttpOnly; SameSite=Strict"], body: Data())
        }
        let cookies = req.headers["cookie"] ?? ""
        guard cookies.split(separator: ";").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "icekast=\(token)" }) else {
            return send(conn, status: 403, reason: "Forbidden", headers: ["Content-Type": "text/plain"],
                        body: Data("Open this from the iceKast app (Open Web Admin).".utf8))
        }
        lock.lock(); let t = target; lock.unlock()
        guard let url = URL(string: "http://\(t.host):\(t.port)\(req.path)") else {
            return send(conn, status: 400, reason: "Bad Request", headers: [:], body: Data())
        }
        var out = URLRequest(url: url)
        out.httpMethod = req.method
        if !req.body.isEmpty { out.httpBody = req.body }
        if let type = req.headers["content-type"] { out.setValue(type, forHTTPHeaderField: "Content-Type") }
        out.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        out.setValue("Basic " + Data("\(t.user):\(t.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        session.dataTask(with: out) { [weak self] data, resp, error in
            guard let self else { return }
            guard let http = resp as? HTTPURLResponse else {
                return self.send(conn, status: 502, reason: "Bad Gateway", headers: ["Content-Type": "text/plain"],
                                 body: Data("iceKast couldn't reach the server (\(error?.localizedDescription ?? "no response")).".utf8))
            }
            var headers: [String: String] = [:]
            for key in ["Content-Type", "Location", "Cache-Control", "Last-Modified"] {
                if let v = http.value(forHTTPHeaderField: key) { headers[key] = v }
            }
            if let loc = headers["Location"], let u = URL(string: loc), u.host != nil {      // keep redirects on the proxy
                headers["Location"] = u.path + (u.query.map { "?" + $0 } ?? "")
            }
            self.send(conn, status: http.statusCode, reason: HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized,
                      headers: headers, body: data ?? Data())
        }.resume()
    }

    private func send(_ conn: NWConnection, status: Int, reason: String, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Passes Icecast's redirects to the browser instead of following them here.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
