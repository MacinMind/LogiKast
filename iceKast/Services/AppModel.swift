import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfig
    let server = IcecastProcess()
    let poller = StatusPoller()

    private var cancellables = Set<AnyCancellable>()

    init() {
        config = Self.load() ?? AppConfig.makeDefault()
        save()

        $config
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)

        // Forward nested objects' changes so views observing AppModel refresh.
        server.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        poller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)

        server.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                if state.isRunning {
                    self.poller.start(port: self.config.server.port, bindAddress: self.config.server.bindAddress)
                } else {
                    self.poller.stop()
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($config, poller.$status)
            .sink { [weak self] config, status in self?.updateBadge(config: config, status: status) }
            .store(in: &cancellables)

        if config.startServerOnLaunch || CommandLine.arguments.contains("--autostart") {
            startServer()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.server.stop() }
        }
    }

    // MARK: Server control

    var issues: [ConfigIssue] { ConfigValidator.issues(for: config) }
    var canStart: Bool { !ConfigValidator.hasErrors(config) }

    func startServer() {
        guard canStart else { return }
        server.start(config: config)
    }

    func stopServer() { server.stop() }

    func applyChanges() {
        guard canStart else { return }
        server.apply(config: config)
        if server.state.isRunning {
            poller.start(port: config.server.port, bindAddress: config.server.bindAddress)
        }
    }

    /// True when the running server doesn't yet reflect the current settings.
    var hasPendingChanges: Bool {
        guard server.state.isRunning, let applied = server.appliedXML else { return false }
        return applied != ConfigWriter.xml(for: config, paths: AppPaths.icecastPaths)
    }

    // MARK: Mounts

    func status(for mount: Mount) -> MountStatus? { poller.status?.mount(mount.name) }

    func addMount() -> Mount {
        var m = Mount()
        var n = config.mounts.count + 1
        while config.mounts.contains(where: { $0.name == "/stream\(n)" }) { n += 1 }
        m.name = "/stream\(n)"
        config.mounts.append(m)
        return m
    }

    func deleteMount(_ id: UUID) {
        config.mounts.removeAll { $0.id == id }
        if case .mount(id) = config.badge { config.badge = .total }
    }

    // MARK: Dock badge

    private func updateBadge(config: AppConfig, status: ServerStatus?) {
        NSApp?.dockTile.badgeLabel = Self.badgeLabel(config: config, status: status)
    }

    /// Text for the dock badge, or nil for no badge. Only shown while the server is reachable.
    static func badgeLabel(config: AppConfig, status: ServerStatus?) -> String? {
        guard let status else { return nil }
        switch config.badge {
        case .none:
            return nil
        case .total:
            return String(status.totalListeners)
        case .mount(let id):
            guard let m = config.mounts.first(where: { $0.id == id }) else { return nil }
            return String(status.mount(m.name)?.listeners ?? 0)
        }
    }

    // MARK: Persistence

    private static func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: AppPaths.configJSON) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(config).write(to: AppPaths.configJSON, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.configJSON.path)
        } catch {
            NSLog("iceKast: could not save config: \(error)")
        }
    }
}
