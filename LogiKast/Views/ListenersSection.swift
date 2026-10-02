import SwiftUI

/// Mount page › Listeners: who is connected right now, with search, sort, a summary and a way to disconnect someone.
/// A table (not a Form) so thousands of listeners stay fast; the list refreshes only while this tab is showing.
struct ListenersSection: View {
    @EnvironmentObject var model: AppModel
    let mount: Mount
    /// For tests: supplies the listeners instead of asking the server.
    var source: (() async -> [Listener]?)?
    @State private var listeners: [Listener]?
    @State private var shown: [Listener] = []
    @State private var summary = ListenerList.summary([])
    @State private var search = ""
    @State private var sort = ListenerList.Sort.newest
    @State private var kickTarget: Listener?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if source == nil, !model.server.isEnabled {
                note("The server is off. Start it to see who is listening.")
            } else if listeners == nil {
                note("Couldn't read the listener list. Check that the server is running and that the admin password in the Access tab hasn't been changed without applying it.", warning: true)
            } else if listeners?.isEmpty == true {
                note("Nobody is listening to this stream right now.")
            } else {
                summaryLine
                HStack {
                    TextField("Search address or player", text: $search).textFieldStyle(.roundedBorder)
                    Picker("Sort", selection: $sort) {
                        ForEach(ListenerList.Sort.allCases) { Text($0.rawValue).tag($0) }
                    }.fixedSize()
                }
                table
                if shown.count != listeners?.count { Text("Showing \(shown.count) of \(listeners?.count ?? 0)").font(.caption).foregroundStyle(.secondary) }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Text("Updates every few seconds (less often with many listeners). Disconnecting a listener drops their connection; their player may simply reconnect, so this is for clearing stuck or unwanted connections, not a permanent block. Listeners on the backup audio are marked.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(mount.name)|\(model.server.isEnabled)|\(mount.backupFile.isEmpty)") { await poll() }
        .onChange(of: search) { _ in refilter() }
        .onChange(of: sort) { _ in refilter() }
        .confirmationDialog("Disconnect this listener?", isPresented: Binding(get: { kickTarget != nil }, set: { if !$0 { kickTarget = nil } }), presenting: kickTarget) { l in
            Button("Disconnect \(l.ip)", role: .destructive) { Task { await kick(l) } }
        } message: { l in
            Text("\(l.player) · connected \(l.connectedText). Their player may reconnect.")
        }
    }

    private var table: some View {
        Table(shown) {
            TableColumn("Address") { l in
                HStack(spacing: 6) {
                    Text(l.ip).font(.system(.body, design: .monospaced))
                    if l.onBackup { Text("backup").font(.caption2).foregroundStyle(.orange) }
                }
            }.width(min: 120, ideal: 150)
            TableColumn("Player") { l in Text(l.player).foregroundStyle(.secondary).lineLimit(1) }
            TableColumn("Connected") { l in Text(l.connectedText).monospacedDigit().foregroundStyle(.secondary) }.width(80)
            TableColumn("") { l in Button("Disconnect…") { kickTarget = l } }.width(100)
        }
        .frame(minHeight: 200)
    }

    private var summaryLine: some View {
        let top = summary.topPlayers.map { "\($0.name) \($0.count)" }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(summary.total) listener\(summary.total == 1 ? "" : "s") from \(summary.uniqueAddresses) address\(summary.uniqueAddresses == 1 ? "" : "es")"
                 + (summary.onBackup > 0 ? " · \(summary.onBackup) hearing the backup" : ""))
                .font(.headline)
            if !top.isEmpty { Text("Players: \(top)").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.callout).foregroundStyle(warning ? Color.orange : Color.secondary)
    }

    private func refilter() { shown = ListenerList.filtered(listeners ?? [], search: search, sort: sort) }

    /// Only touches state when something changed, so an idle audience doesn't redraw the table every poll.
    private func apply(_ new: [Listener]?) {
        guard new != listeners else { return }
        listeners = new
        summary = ListenerList.summary(new ?? [])
        refilter()
    }

    private func poll() async {
        guard source != nil || model.server.isEnabled else { apply(nil); return }
        while !Task.isCancelled {
            let new: [Listener]?
            if let source { new = await source() } else { new = await model.listeners(of: mount) }
            if Task.isCancelled { break }
            apply(new)
            let seconds = ListenerList.refreshInterval(listenerCount: new?.count ?? 0)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    private func kick(_ l: Listener) async {
        let ok = await model.kick(l, from: mount)
        message = ok ? "Disconnected \(l.ip)." : "Couldn't disconnect \(l.ip). They may have already left."
        apply(await model.listeners(of: mount))
    }
}
