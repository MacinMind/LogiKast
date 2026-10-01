import SwiftUI

struct ServerView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLog = false

    var body: some View {
        Form {
            Section {
                header
                if model.server.state == .needsApproval {
                    Button("Open Login Items Settings…") { model.server.openLoginItemsSettings() }
                }
                IssuesView(issues: model.issues)
                if model.hasPendingChanges { pendingBanner }
            }

            Section("Network") {
                IntField(title: "Port", value: $model.config.server.port)
                LabeledContent("Public host name") {
                    TextField("", text: $model.config.server.hostname, prompt: Text("localhost"))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Listen on") {
                    TextField("", text: $model.config.server.bindAddress, prompt: Text("All interfaces"))
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Limits") {
                IntField(title: "Max listeners (all mounts)", value: $model.config.server.maxClients)
                IntField(title: "Max encoder connections", value: $model.config.server.maxSources)
                IntField(title: "Default burst size", value: $model.config.server.burstSize, suffix: "bytes")
                IntField(title: "Queue size", value: $model.config.server.queueSize, suffix: "bytes")
                IntField(title: "Listener timeout", value: $model.config.server.clientTimeout, suffix: "s")
                IntField(title: "Encoder timeout", value: $model.config.server.sourceTimeout, suffix: "s")
            }

            Section("Passwords") {
                PasswordRow(label: "Encoder password", value: $model.config.server.sourcePassword)
                PasswordRow(label: "Admin password", value: $model.config.server.adminPassword)
                LabeledContent("Admin user") {
                    TextField("", text: $model.config.server.adminUser).multilineTextAlignment(.trailing)
                }
            }

            Section("Station info") {
                LabeledContent("Location") {
                    TextField("", text: $model.config.server.location, prompt: Text("Earth")).multilineTextAlignment(.trailing)
                }
                LabeledContent("Admin email") {
                    TextField("", text: $model.config.server.adminEmail, prompt: Text("you@example.com")).multilineTextAlignment(.trailing)
                }
            }

            Section("App") {
                Text("The server runs in the background: it keeps running when you close or quit iceKast, restarts if it stops unexpectedly, and starts when you log in. Use Stop Server to turn it off.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Dock badge shows", selection: $model.config.badge) {
                    Text("Nothing").tag(BadgeTarget.none)
                    Text("Total listeners").tag(BadgeTarget.total)
                    ForEach(model.config.mounts) { m in
                        Text("Listeners on \(m.name)").tag(BadgeTarget.mount(m.id))
                    }
                }
            }

            Section {
                DisclosureGroup("Server log", isExpanded: $showLog) {
                    ScrollView {
                        Text(model.server.logLines.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server")
    }

    private var header: some View {
        HStack(spacing: 12) {
            StatusDot(color: statusColor).scaleEffect(1.4)
            VStack(alignment: .leading) {
                Text(statusText).font(.headline)
                if let s = model.poller.status {
                    Text("\(s.mounts.count) mount\(s.mounts.count == 1 ? "" : "s") live · \(s.totalListeners) listener\(s.totalListeners == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var pendingBanner: some View {
        HStack {
            Label("Changes not applied yet.", systemImage: "arrow.triangle.2.circlepath")
            Spacer()
            Button("Apply Changes") { model.applyChanges() }
                .disabled(!model.canStart)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusText: String {
        switch model.server.state {
        case .stopped: "Server is off"
        case .running: model.poller.reachable ? "Server is running" : "Server is starting…"
        case .needsApproval: "Allow iceKast in System Settings › Login Items to run the server in the background."
        case .failed(let msg): msg
        }
    }

    private var statusColor: Color {
        switch model.server.state {
        case .stopped: .gray
        case .running: model.poller.reachable ? .green : .orange
        case .needsApproval: .orange
        case .failed: .red
        }
    }
}

struct PasswordRow: View {
    let label: String
    @Binding var value: String
    @State private var revealed = false

    var body: some View {
        LabeledContent(label) {
            HStack {
                Group {
                    if revealed { TextField("", text: $value) } else { SecureField("", text: $value) }
                }
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 200)
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                Button { value = Password.random() } label: { Image(systemName: "dice") }
                    .buttonStyle(.borderless).help("Generate a new random password")
            }
        }
    }
}
