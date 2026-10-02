import Foundation

@MainActor
final class StatusPoller: ObservableObject {
    @Published private(set) var status: ServerStatus?
    @Published private(set) var reachable = false

    private var task: Task<Void, Never>?
    /// Admin login to read the hidden backup mounts' listeners; return nil when nothing needs it.
    var adminLogin: (() -> (user: String, password: String)?)?
    /// Admin login for the bandwidth meter. Only asked for while the window is showing, so a closed window costs nothing.
    var meterLogin: (() -> (user: String, password: String)?)?
    @Published private(set) var bandwidth: BandwidthRates?
    private var meter = BandwidthMeter()

    func start(port: Int, bindAddress: String, interval: TimeInterval = 2) {
        stop()
        let host = (bindAddress.isEmpty || bindAddress == "0.0.0.0") ? "127.0.0.1" : bindAddress
        guard let url = URL(string: "http://\(host):\(port)/status-json.xsl"),
              let adminURL = URL(string: "http://\(host):\(port)/admin/stats.xml") else { return }
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
                let meterLogin = parsed == nil ? nil : self?.meterLogin?()
                if parsed != nil, let login = meterLogin ?? self?.adminLogin?() {
                    var req = URLRequest(url: adminURL)
                    let token = Data("\(login.user):\(login.password)".utf8).base64EncodedString()
                    req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
                    if let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
                        parsed?.backupMounts = AdminStats.backupMounts(from: data)
                        if meterLogin != nil {
                            let rates = self?.meter.update(AdminStats.byteCounters(from: data), at: Date())
                            if let rates { self?.bandwidth = rates }
                        }
                    }
                }
                if meterLogin == nil { self?.meter.reset(); if self?.bandwidth != nil { self?.bandwidth = nil } }
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
        bandwidth = nil
        meter.reset()
    }
}
