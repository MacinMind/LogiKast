import SwiftUI

/// Mount page › Listeners: who is connected right now, with a way to disconnect someone.
struct ListenersSection: View {
    @EnvironmentObject var model: AppModel
    let mount: Mount
    @State private var listeners: [Listener]?
    @State private var kickTarget: Listener?
    @State private var message: String?

    var body: some View {
        Section {
            if !model.server.isEnabled {
                Text("The server is off. Start it to see who is listening.").foregroundStyle(.secondary)
            } else if let listeners {
                if listeners.isEmpty {
                    Text("Nobody is listening to this stream right now.").foregroundStyle(.secondary)
                } else {
                    ForEach(listeners) { l in row(l) }
                }
            } else {
                Text("Couldn't read the listener list. Check that the server is running and the admin password in the Access tab hasn't been changed without applying it.")
                    .foregroundStyle(.orange).font(.callout)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text(headerText)
        } footer: {
            Text("Updates every few seconds. Disconnecting a listener drops their connection; their player may simply reconnect, so this is for clearing stuck or unwanted connections, not a permanent block. Listeners on the backup audio are marked.")
        }
        .task(id: "\(mount.name)|\(model.server.isEnabled)|\(mount.backupFile.isEmpty)") { await poll() }
        .confirmationDialog("Disconnect this listener?", isPresented: Binding(get: { kickTarget != nil }, set: { if !$0 { kickTarget = nil } }), presenting: kickTarget) { l in
            Button("Disconnect \(l.ip)", role: .destructive) { Task { await kick(l) } }
        } message: { l in
            Text("\(l.player) · connected \(l.connectedText). Their player may reconnect.")
        }
    }

    private var headerText: String {
        guard let listeners else { return "Listeners" }
        return "Listeners · \(listeners.count)"
    }

    private func row(_ l: Listener) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(l.ip).font(.system(.body, design: .monospaced))
                    if l.onBackup { Text("hearing backup").font(.caption).foregroundStyle(.orange) }
                }
                Text(l.player).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Text(l.connectedText).foregroundStyle(.secondary).monospacedDigit()
            Button("Disconnect…") { kickTarget = l }
        }
    }

    private func poll() async {
        guard model.server.isEnabled else { listeners = nil; return }
        while !Task.isCancelled {
            listeners = await model.listeners(of: mount)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func kick(_ l: Listener) async {
        let ok = await model.kick(l, from: mount)
        message = ok ? "Disconnected \(l.ip)." : "Couldn't disconnect \(l.ip). They may have already left."
        listeners = await model.listeners(of: mount)
    }
}
