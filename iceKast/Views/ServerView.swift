import SwiftUI

struct ServerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StatusPanel {
                header
                if model.server.state == .needsApproval {
                    Button("Open Login Items Settings…") { model.server.openLoginItemsSettings() }
                }
                IssuesView(issues: model.issues)
                if model.hasPendingChanges { pendingBanner }
            }
            SegmentedTabs(selection: $model.serverTab)
            if model.serverTab == .app {
                // Settings stay their natural size; the log takes all the remaining height, so a taller window shows more of it.
                Form { appTab }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .frame(height: 175)
                logView
            } else {
                Form { tabContent }
                    .formStyle(.grouped)
            }
        }
        .navigationTitle("Server")
    }

    @ViewBuilder private var tabContent: some View {
        switch model.serverTab {
        case .network: networkTab
        case .access: accessTab
        case .alerts: alertsTab
        case .app: appTab
        }
    }

    @ViewBuilder private var networkTab: some View {
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
    }

    @ViewBuilder private var accessTab: some View {
            Section {
                PasswordRow(label: "Encoder password", value: $model.config.server.sourcePassword)
                PasswordRow(label: "Admin password", value: $model.config.server.adminPassword)
                LabeledContent("Admin user") {
                    TextField("", text: $model.config.server.adminUser).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Passwords")
            } footer: {
                Text("Encoders connect with the username “source” and the encoder password. The admin user and password are only for Icecast's web admin pages (the Open Web Admin button above), never for encoders.")
            }

            Section("Station info") {
                LabeledContent("Location") {
                    TextField("", text: $model.config.server.location, prompt: Text("Earth")).multilineTextAlignment(.trailing)
                }
                LabeledContent("Admin email") {
                    TextField("", text: $model.config.server.adminEmail, prompt: Text("you@example.com")).multilineTextAlignment(.trailing)
                }
            }
    }

    @ViewBuilder private var alertsTab: some View {
            Section {
                Toggle("Send notifications", isOn: $model.config.notifications.enabled)
                if model.config.notifications.enabled {
                    Toggle("Encoder connects or drops off", isOn: $model.config.notifications.encoderEvents)
                    Toggle("Server stops responding or recovers", isOn: $model.config.notifications.serverProblems)
                    Toggle("Listener limit reached", isOn: $model.config.notifications.listenerLimit)
                }
                HStack {
                    Button("Send Test Notification") { model.notifier.sendTest() }
                    if model.notifier.permission == .denied {
                        Button("Open Notification Settings…") { model.notifier.openSystemSettings() }
                    }
                    Spacer()
                }
                if model.notifier.permission == .denied {
                    Label("Notifications are turned off for iceKast in System Settings, so no alerts can appear.", systemImage: "bell.slash")
                        .foregroundStyle(.orange).font(.callout)
                }
                Toggle("Open iceKast when I log in", isOn: Binding(get: { model.loginItem.isEnabled }, set: { model.loginItem.set($0) }))
                if model.loginItem.needsApproval {
                    Button("Allow in Login Items Settings…") { model.loginItem.openSettings() }
                }
                if let err = model.loginItem.lastError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Alerts need iceKast to be running; it sits in the menu bar, and \"Open iceKast when I log in\" keeps it there. The server itself keeps running without the app, but nobody is told if it has a problem.")
            }
    }

    @ViewBuilder private var appTab: some View {
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

    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.server.logLines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("logEnd")
                }
                // Newest lines are at the bottom: open there and stay with them as new lines arrive.
                .onAppear { proxy.scrollTo("logEnd", anchor: .bottom) }
                .onChange(of: model.server.logLines.count) { _ in proxy.scrollTo("logEnd", anchor: .bottom) }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity)
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
            if model.server.isEnabled {
                Button("Open Web Admin") { model.openWebAdmin() }
                    .help("Opens Icecast's own admin pages in your browser. It asks for the admin user and password (see Access).")
                Button("Restart Server…") { model.promptForRestart() }
            }
        }
    }

    private var pendingBanner: some View {
        HStack {
            Label(model.server.requiresRestart(for: model.config)
                  ? "Changes not applied yet. These need a server restart."
                  : "Changes not applied yet.", systemImage: "arrow.triangle.2.circlepath")
            Spacer()
            Button(model.server.requiresRestart(for: model.config) ? "Restart & Apply…" : "Apply Changes") { model.applyChanges() }
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
