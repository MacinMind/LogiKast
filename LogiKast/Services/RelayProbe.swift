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
    static func get(host: String, port: Int, path: String, timeout: TimeInterval = 4, maxBytes: Int = 1_000_000) async -> (status: Int, body: Data)? {
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
                    let request = "GET \(path) HTTP/1.0\r\nHost: \(host):\(port)\r\nUser-Agent: LogiKast\r\nConnection: close\r\n\r\n"
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
