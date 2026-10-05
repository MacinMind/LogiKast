import SwiftUI

/// The rows that describe another server a stream is taken from: used for a relay mount's source and for a backup stream.
struct RelayEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var relay: RelaySource
    @State private var probe: RelayProbe.Result?
    @State private var checking = false

    /// Changes whenever something the check depends on changes.
    private struct CheckKey: Equatable { var server: String; var port: Int; var mount: String; var ownInstance: String? }
    private var checkKey: CheckKey {
        CheckKey(server: relay.server.trimmingCharacters(in: .whitespaces), port: relay.port, mount: relay.mount,
                 ownInstance: model.poller.status?.instanceUUID)
    }

    var body: some View {
        LabeledContent("Server") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("", text: $relay.server, prompt: Text("e.g. radio.example.com"))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                Text(":").foregroundStyle(.secondary)
                TextField("", value: $relay.port, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .help("The other server's port")
            }
        }
        LabeledContent("Mount on that server") {
            TextField("", text: $relay.mount, prompt: Text("/live")).multilineTextAlignment(.trailing).autocorrectionDisabled()
        }
        LabeledContent("Login (if it asks)") {
            HStack(spacing: 8) {
                TextField("", text: $relay.username, prompt: Text("Username")).multilineTextAlignment(.trailing).autocorrectionDisabled()
                SecureField("", text: $relay.password, prompt: Text("Password")).multilineTextAlignment(.trailing)
            }
        }
        Toggle("Only pull the stream while someone is listening", isOn: $relay.onDemand)
            .task(id: checkKey) { await check() }          // on a row that is always there: an empty row would never run it
        probeRow
    }

    private func check() async {
        probe = nil
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }     // tests make no network calls
        guard relay.isSet, (1...65535).contains(relay.port) else { checking = false; return }
        checking = true
        try? await Task.sleep(nanoseconds: 800_000_000)               // wait until typing pauses
        guard !Task.isCancelled else { return }
        let result = await RelayProbe.probe(relay, ownInstance: model.poller.status?.instanceUUID)
        guard !Task.isCancelled else { return }
        probe = result
        checking = false
    }

    @ViewBuilder private var probeRow: some View {
        if checking {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the server…").foregroundStyle(.secondary).font(.callout) }
        } else if let probe {
            switch probe {
            case .thisServer:
                Label("This is your own server. A mount can't take its audio from itself, so enter a different server.",
                      systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            case .unreachable:
                Label("Can't reach \(relay.server.trimmingCharacters(in: .whitespaces)):\(String(relay.port)) from this Mac right now.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            case .live(let mount):
                Label("Reached the server. \(relay.mount) is on air" + (relayDetail(mount).map { " · \($0)" } ?? "") + ".",
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            case .listedNotLive:
                // Not a fault: a hosted server can serve this mount through a fallback while it lists the mount as not live.
                Label("Reached the server. It lists \(relay.mount) but not as a live stream, so it may be playing through a fallback.",
                      systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
            case .notListed:
                Label("Reached the server, but it doesn't list \(relay.mount). The mount may be hidden or not set up there.",
                      systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
            case .reachable:
                Label("Reached the server.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            }
        }
    }

    private func relayDetail(_ m: MountStatus) -> String? {
        var parts: [String] = []
        if let f = m.contentType.flatMap(StreamFormat.init(contentType:)) { parts.append(f.label) }
        if let b = m.bitrate { parts.append("\(b) kbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The mounts another server hands over, and what each is doing here (read-only).
struct RelayedMountList: View {
    @EnvironmentObject var model: AppModel
    let mounts: [String]
    let onDemand: Bool
    private let shown = 20

    var body: some View {
        let own = Set(model.config.mounts.map(\.name))
        let limits = model.config.server.effectiveLimits
        let needed = model.config.mounts.count + model.config.mounts.filter { !$0.backupFile.isEmpty || $0.usesBackupRelay }.count
                     + mounts.filter { !own.contains($0) }.count
        Label(mounts.isEmpty ? "The login works, but the other server has no mounts to relay right now."
                             : "The login works. \(mounts.count) mount\(mounts.count == 1 ? "" : "s") would be relayed:",
              systemImage: mounts.isEmpty ? "info.circle" : "checkmark.circle.fill")
            .foregroundStyle(mounts.isEmpty ? Color.secondary : Color.green).font(.callout)
        ForEach(mounts.prefix(shown), id: \.self) { path in
            HStack {
                Text(path).font(.system(.callout, design: .monospaced))
                Spacer()
                Text(state(of: path, isOwn: own.contains(path))).font(.callout).foregroundStyle(.secondary)
            }
        }
        if mounts.count > shown {
            Text("and \(mounts.count - shown) more").font(.callout).foregroundStyle(.secondary)
        }
        let clashes = mounts.filter { own.contains($0) }
        if !clashes.isEmpty {
            Label("\(clashes.count == 1 ? "\(clashes[0]) has" : "\(clashes.count) of these have") the same name as your own mount\(clashes.count == 1 ? "" : "s"). Whichever source connects first keeps the mount, so your encoder can be turned away while the relay is using it. Rename your mount to avoid that.",
                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        }
        if needed > limits.sources {
            Label("These need \(needed) encoder connections, but your limit allows \(limits.sources). Raise Max listeners and Max encoder connections under Server › Limits, or some of them will not connect.",
                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        }
    }

    private func state(of path: String, isOwn: Bool) -> String {
        if let s = model.poller.status?.mount(path) {
            return "On air · \(s.listeners) listener\(s.listeners == 1 ? "" : "s")" + (isOwn ? " · same name as yours" : "")
        }
        if isOwn { return "Same name as your mount" }
        return onDemand ? "Waiting for a listener" : "Not connected yet"
    }
}
