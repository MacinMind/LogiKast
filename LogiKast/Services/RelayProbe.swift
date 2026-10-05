import Foundation
import Network

/// Asks the server a mount would relay from what it is, so LogiKast can say whether it can be reached, whether the mount
/// is there, and whether it is in fact this very server (which would make a loop).
enum RelayProbe {
    enum Result: Equatable {
        /// The address leads back to this server (it can be a name that points at this Mac through the router).
        case thisServer
        /// The server answered and the mount is on air.
        case live(MountStatus)
        /// The server lists the mount but not as a live stream (typically it plays through a fallback).
        case listedNotLive
        /// The server answered but doesn't list the mount (it may be hidden, or not set up).
        case notListed
        /// The server answered; there was no mount to look for (a Shoutcast server relays "/").
        case reachable
        case unreachable
    }

    /// Pure decision, so it can be tested without a network.
    static func classify(_ remote: ServerStatus, asking r: RelaySource, ownInstance: String?) -> Result {
        if let own = ownInstance, let theirs = remote.instanceUUID, own == theirs { return .thisServer }
        // A Shoutcast server relays "/", which has no mount to look for.
        guard r.mount != "/" else { return .reachable }
        if let live = remote.mount(r.mount) { return .live(live) }
        return remote.listedPaths.contains(r.mount) ? .listedNotLive : .notListed
    }

    static func probe(_ r: RelaySource, ownInstance: String?) async -> Result {
        let host = r.server.trimmingCharacters(in: .whitespaces)
        guard let reply = await get(host: host, port: r.port, path: "/status-json.xsl"),
              reply.status == 200, let status = StatusParser.parse(reply.body) else { return .unreachable }
        return classify(status, asking: r, ownInstance: ownInstance)
    }

    /// A plain HTTP GET over a direct connection. (URLSession refuses plain http:// to a named host under App Transport
    /// Security, and a relay's other server is whatever address the user enters.) HTTP/1.0 with the connection closed
    /// afterwards, so the reply is simply everything until the server hangs up.
    static func get(host: String, port: Int, path: String, headers: [String: String] = [:], timeout: TimeInterval = 4,
                    maxBytes: Int = 1_000_000) async -> (status: Int, body: Data)? {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { (continuation: CheckedContinuation<(status: Int, body: Data)?, Never>) in
            let queue = DispatchQueue(label: "logikast.relayprobe")
            var finished = false
            var received = Data()
            func finish(_ value: (status: Int, body: Data)?) {
                queue.async {
                    guard !finished else { return }
                    finished = true
                    connection.cancel()
                    continuation.resume(returning: value)
                }
            }
            func parse() -> (status: Int, body: Data)? {
                guard let split = received.range(of: Data("\r\n\r\n".utf8)),
                      let head = String(data: received[..<split.lowerBound], encoding: .isoLatin1),
                      let first = head.split(separator: "\r\n").first,
                      let code = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return nil }
                return (code, received[split.upperBound...])
            }
            func readMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data { received.append(data) }
                    if error != nil || isComplete || received.count > maxBytes {
                        finish(parse())
                    } else {
                        readMore()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let extra = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
                    let request = "GET \(path) HTTP/1.0\r\nHost: \(host):\(port)\r\nUser-Agent: LogiKast\r\n\(extra)Connection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if error != nil { finish(nil) } else { readMore() }
                    })
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(finished ? nil : parse()) }
            connection.start(queue: queue)
        }
    }
}

/// Asks the other server of a "relay everything" setup which mounts it would hand over, using the relay login.
enum MasterProbe {
    enum Result: Equatable {
        /// The login works; these are the mounts the other server offers.
        case ok([String])
        case badLogin
        case unreachable
        /// The address leads back to this server.
        case thisServer
    }

    /// The mounts in Icecast's /admin/streamlist.txt: one per line.
    static func parseList(_ body: Data) -> [String] {
        String(decoding: body, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
    }

    static func probe(_ m: MasterRelay, ownInstance: String?) async -> Result {
        let host = m.server.trimmingCharacters(in: .whitespaces)
        if let own = ownInstance,
           let reply = await RelayProbe.get(host: host, port: m.port, path: "/status-json.xsl"),
           reply.status == 200, StatusParser.parse(reply.body)?.instanceUUID == own {
            return .thisServer
        }
        let login = Data("\(m.username.isEmpty ? "relay" : m.username):\(m.password)".utf8).base64EncodedString()
        guard let reply = await RelayProbe.get(host: host, port: m.port, path: "/admin/streamlist.txt",
                                               headers: ["Authorization": "Basic \(login)"]) else { return .unreachable }
        switch reply.status {
        case 200: return .ok(parseList(reply.body))
        case 401, 403: return .badLogin
        default: return .unreachable
        }
    }
}
