import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var config: AppConfig
    let server = IcecastService()
    let poller = StatusPoller()

    /// Set when a change needs a server restart; the UI shows a confirmation dialog.
    @Published var restartPrompt: RestartPrompt?
    /// Shows the setup assistant: automatically on a new install, or from Help › Setup Assistant.
    @Published var showSetup = false
    /// Asked before the assistant opens on a station that is already set up.
    @Published var showSetupWarning = false
    /// True when the assistant was opened on an existing setup (it then warns and confirms changes).
    private(set) var setupIsRerun = false

    struct RestartPrompt: Identifiable {
        let id = UUID()
        var reason: String
        var listeners: Int
        var encoders: Int
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        config = Self.load() ?? AppConfig.makeDefault()
        save()
        AppPaths.syncShare()
        showSetup = !config.setupCompleted || CommandLine.arguments.contains("--show-setup")
        setupIsRerun = config.setupCompleted

        $config
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)

        // Forward nested objects' changes so views observing AppModel refresh.
        server.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        poller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)

        server.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.poller.start(port: self.config.server.port, bindAddress: self.config.server.bindAddress)
                } else {
                    self.poller.stop()
                }
            }
            .store(in: &cancellables)

        poller.$reachable
            .removeDuplicates()
            .sink { [weak self] r in self?.server.reachabilityChanged(r) }
            .store(in: &cancellables)

        Publishers.CombineLatest($config, poller.$status)
            .sink { [weak self] config, status in self?.updateBadge(config: config, status: status) }
            .store(in: &cancellables)

        // The server runs as a background service, so quitting iceKast leaves it running.
        if CommandLine.arguments.contains("--autostart"), !server.isEnabled {
            startServer()
        }
        if CommandLine.arguments.contains("--stop") { stopServer() }   // for scripted tests
        if CommandLine.arguments.contains("--apply") { applyChanges() }
    }

    // MARK: Setup assistant

    /// Opens the assistant. On an existing setup it asks first, because the assistant edits
    /// the server settings and the first mount.
    func requestSetup() {
        if config.setupCompleted {
            showSetupWarning = true
        } else {
            setupIsRerun = false
            showSetup = true
        }
    }

    func confirmSetupRerun() {
        showSetupWarning = false
        setupIsRerun = true
        showSetup = true
    }

    /// Mount names with live listener counts, for the warning text.
    var setupWarningMessage: String {
        let mounts = config.mounts.map { m -> String in
            let l = status(for: m)?.listeners
            return l.map { "\(m.name) (\($0) listening)" } ?? m.name
        }.joined(separator: ", ")
        return "You already have a station set up (\(mounts)). The assistant is for first-time setup: it changes your server settings and your first mount, and encoders using a mount you rename will be disconnected.\n\nTo add another stream, cancel and use the + button above the mount list instead.\n\nNothing is saved until you confirm at the end."
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
        if server.requiresRestart(for: config) {
            promptForRestart(reason: "Changing the port or network interface needs the server to restart.")
        } else {
            server.apply(config: config)
        }
    }

    /// Ask before restarting: listeners and encoders are disconnected.
    func promptForRestart(reason: String = "The server will be stopped and started again.") {
        guard server.isEnabled, canStart else { return }
        restartPrompt = RestartPrompt(reason: reason,
                                      listeners: poller.status?.totalListeners ?? 0,
                                      encoders: poller.status?.mounts.count ?? 0)
    }

    func confirmRestart() {
        restartPrompt = nil
        guard canStart else { return }
        server.apply(config: config, forceRestart: true)
        poller.start(port: config.server.port, bindAddress: config.server.bindAddress)
    }

    /// True when the running server doesn't yet reflect the current settings.
    var hasPendingChanges: Bool {
        guard server.isEnabled, let applied = server.appliedXML else { return false }
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
