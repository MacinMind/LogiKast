import Foundation

@MainActor
final class StatusPoller: ObservableObject {
    @Published private(set) var status: ServerStatus?
    @Published private(set) var reachable = false

    private var task: Task<Void, Never>?

    func start(port: Int, bindAddress: String, interval: TimeInterval = 2) {
        stop()
        let host = (bindAddress.isEmpty || bindAddress == "0.0.0.0") ? "127.0.0.1" : bindAddress
        guard let url = URL(string: "http://\(host):\(port)/status-json.xsl") else { return }
        task = Task { [weak self] in
            let session = URLSession(configuration: {
                let c = URLSessionConfiguration.ephemeral
                c.timeoutIntervalForRequest = 2
                c.requestCachePolicy = .reloadIgnoringLocalCacheData
                return c
            }())
            while !Task.isCancelled {
                var parsed: ServerStatus?
                if let (data, resp) = try? await session.data(from: url),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    parsed = StatusParser.parse(data)
                }
                if Task.isCancelled { break }
                self?.status = parsed
                self?.reachable = parsed != nil
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// For tests and previews: show a given status without a running server.
    func injectForTesting(status: ServerStatus?) {
        self.status = status
        self.reachable = status != nil
    }

    func stop() {
        task?.cancel()
        task = nil
        status = nil
        reachable = false
    }
}
