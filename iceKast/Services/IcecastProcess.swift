import Foundation

@MainActor
final class IcecastProcess: ObservableObject {
    enum State: Equatable {
        case stopped
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    @Published private(set) var state = State.stopped
    @Published private(set) var logLines: [String] = []
    /// The icecast.xml currently loaded by the running server.
    @Published private(set) var appliedXML: String?

    private var process: Process?
    private var stopRequested = false
    private var runningListenKey = ""
    private var runningPort = 0
    private let maxLogLines = 400

    private func listenKey(_ c: AppConfig) -> String { "\(c.server.port)|\(c.server.bindAddress)" }

    func start(config: AppConfig) {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: AppPaths.icecastExecutable.path) else {
            state = .failed("The bundled Icecast server is missing from the app.")
            return
        }
        if PortCheck.isInUse(port: config.server.port) {
            state = .failed("Port \(config.server.port) is already in use by another app. Choose a different port in Network settings.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: AppPaths.logDir, withIntermediateDirectories: true)
            let xml = ConfigWriter.xml(for: config, paths: AppPaths.icecastPaths)
            try Self.writeConfig(xml)
            appliedXML = xml
        } catch {
            state = .failed("Could not write the server configuration: \(error.localizedDescription)")
            return
        }

        let p = Process()
        p.executableURL = AppPaths.icecastExecutable
        p.arguments = ["-c", AppPaths.icecastXML.path]
        p.currentDirectoryURL = AppPaths.supportDir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(text) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor in self?.didExit(status: status) }
        }

        stopRequested = false
        logLines.removeAll()
        do {
            try p.run()
            process = p
            runningListenKey = listenKey(config)
            runningPort = config.server.port
            state = .running
        } catch {
            state = .failed("Could not start Icecast: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        stopRequested = true
        p.terminate()
    }

    /// Applies new settings. Mount, limit and password changes are hot-reloaded
    /// (SIGHUP) so live streams are not interrupted; port changes need a restart.
    /// Returns true if a restart was required (sources must reconnect).
    @discardableResult
    func apply(config: AppConfig) -> Bool {
        guard let p = process, p.isRunning else { return false }
        if listenKey(config) != runningListenKey {
            restart(config: config)
            return true
        }
        do {
            let xml = ConfigWriter.xml(for: config, paths: AppPaths.icecastPaths)
            try Self.writeConfig(xml)
            appliedXML = xml
            kill(p.processIdentifier, SIGHUP)
        } catch {
            state = .failed("Could not write the server configuration: \(error.localizedDescription)")
        }
        return false
    }

    func restart(config: AppConfig) {
        guard let p = process, p.isRunning else { start(config: config); return }
        stopRequested = true
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.state = .stopped
                self?.start(config: config)
            }
        }
        p.terminate()
    }

    /// The config holds passwords, so keep it readable by the owner only.
    private static func writeConfig(_ xml: String) throws {
        try xml.write(to: AppPaths.icecastXML, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.icecastXML.path)
    }

    private func didExit(status: Int32) {
        process = nil
        appliedXML = nil
        if stopRequested || status == 0 {
            state = .stopped
        } else {
            if logLines.contains(where: { $0.contains("Can not listen") }) {
                state = .failed("Port \(runningPort) is already in use by another app. Choose a different port in Network settings.")
            } else {
                let hint = logLines.last { $0.contains("EROR") || $0.contains("ERROR") }
                state = .failed(hint ?? "Icecast stopped unexpectedly (exit code \(status)).")
            }
        }
    }

    private func append(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        logLines.append(contentsOf: lines)
        if logLines.count > maxLogLines { logLines.removeFirst(logLines.count - maxLogLines) }
    }
}
