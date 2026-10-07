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
                if model.hasPendingChanges { PendingChangesBanner() }
            }
            SegmentedTabs(selection: $model.serverTab)
            if model.serverTab == .app {
                // Settings stay their natural size; the log takes all the remaining height, so a taller window shows more of it.
                Form { appTab }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .frame(height: appFormHeight)
                logView
            } else {
                Form { tabContent }
                    .formStyle(.grouped)
            }
        }
    }

    /// The App section is a fixed-height form (the log below takes the rest), so it grows for the rows that only sometimes appear.
    private var appFormHeight: CGFloat {
        195 + (model.loginItem.needsApproval ? 44 : 0) + (model.loginItem.lastError != nil ? 34 : 0)
    }

    @ViewBuilder private var tabContent: some View {
        switch model.serverTab {
        case .setup: setupTab
        case .limits: limitsTab
        case .relay: relayTab
        case .alerts: alertsTab
        case .app: appTab
        case .updates: UpdateSettings(updater: model.updater)
        }
    }

    @ViewBuilder private var setupTab: some View {
            Section("This server") {
                IntField(title: "Port", value: $model.config.server.port)
                LabeledContent("Public host name") {
                    TextField("", text: $model.config.server.hostname, prompt: Text("localhost"))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Listen on") {
                    TextField("", text: $model.config.server.bindAddress, prompt: Text("All interfaces"))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Location") {
                    TextField("", text: $model.config.server.location, prompt: Text("Earth")).multilineTextAlignment(.trailing)
                }
                LabeledContent("Admin email") {
                    TextField("", text: $model.config.server.adminEmail, prompt: Text("you@example.com")).multilineTextAlignment(.trailing)
                }
            }

            Section {
                PasswordRow(label: "Encoder password", value: $model.config.server.sourcePassword,
                            consequence: "Every encoder using it is disconnected when you apply the change, and needs the new password to connect again.")
                PasswordRow(label: "Admin password", value: $model.config.server.adminPassword,
                            consequence: "Anyone who signs in to the web admin pages with it needs the new one.")
                LabeledContent("Admin user") {
                    TextField("", text: $model.config.server.adminUser).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Passwords")
            } footer: {
                FooterText("Encoders log in as “source” with the encoder password. The admin login is for Web Admin only.")
            }
    }

    @ViewBuilder private var limitsTab: some View {
            Section("Limits") {
                IntField(title: "Max listeners (all mounts)", value: $model.config.server.maxClients)
                IntField(title: "Max encoder connections", value: $model.config.server.maxSources)
                IntField(title: "Default burst size", value: $model.config.server.burstSize, suffix: "bytes")
                IntField(title: "Queue size", value: $model.config.server.queueSize, suffix: "bytes")
                IntField(title: "Listener timeout", value: $model.config.server.clientTimeout, suffix: "s")
                IntField(title: "Encoder timeout", value: $model.config.server.sourceTimeout, suffix: "s")
            }
    }

    @ViewBuilder private var relayTab: some View {
            Section {
                Toggle("Let other Icecast servers relay all my mounts", isOn: Binding(
                    get: { model.config.server.allowRelaying },
                    set: { on in
                        model.config.server.allowRelaying = on
                        if on, model.config.server.relayPassword.isEmpty { model.config.server.relayPassword = Password.random() }
                    }))
                if model.config.server.allowRelaying {
                    PasswordRow(label: "Relay password", value: $model.config.server.relayPassword,
                                consequence: "Any server that relays all your mounts with it must be given the new one, or it will stop receiving them.")
                    CopyableRow(label: "Relay user", value: "relay")
                    CopyableRow(label: "Server", value: "\(model.config.server.hostname.isEmpty ? "localhost" : model.config.server.hostname):\(model.config.server.port)")
                }
            } header: {
                Text("Let others relay everything")
            } footer: {
                FooterText("Not needed to let someone relay one mount: give them that mount's address (Mount › Advanced › Relaying by other servers). That needs no password. This is for a server that should pick up all your mounts automatically, including new ones. Hidden backup mounts are not shared.")
            }

            masterRelaySection
    }

    // MARK: Relay everything from another server

    private var masterBinding: Binding<MasterRelay> { $model.config.server.masterRelay }

    @State private var masterResult: MasterProbe.Result?
    @State private var masterChecking = false

    @ViewBuilder private var masterRelaySection: some View {
        let master = model.config.server.masterRelay
        Section {
            Toggle("Relay all mounts from another Icecast server", isOn: masterBinding.enabled)
                .task(id: MasterCheckKey(master: master, ownInstance: model.poller.status?.instanceUUID)) { await watchMaster() }
            if model.server.isEnabled, model.server.masterRelayNeedsRestart(for: model.config) {
                HStack {
                    Label(master.isActive ? "The server must be restarted before it starts relaying." : "The server must be restarted to stop relaying.",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Button("Restart & Apply…") { model.applyChanges() }.disabled(!model.canStart)
                }
            }
            if master.enabled {
                LabeledContent("Server") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        TextField("", text: masterBinding.server, prompt: Text("e.g. radio.example.com"))
                            .multilineTextAlignment(.trailing).autocorrectionDisabled()
                        Text(":").foregroundStyle(.secondary)
                        TextField("", value: masterBinding.port, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing).frame(width: 56)
                    }
                }
                LabeledContent("Relay login") {
                    HStack(spacing: 8) {
                        TextField("", text: masterBinding.username, prompt: Text("relay")).multilineTextAlignment(.trailing).autocorrectionDisabled()
                        SecureField("", text: masterBinding.password, prompt: Text("Password")).multilineTextAlignment(.trailing)
                    }
                }
                Toggle("Only pull streams while someone is listening", isOn: masterBinding.onDemand)
                masterStatusRows(master)
            }
        } header: {
            Text("Relay everything from another server")
        } footer: {
            FooterText("Takes every visible mount from the other Icecast server, under the same names, and picks up new ones within about 20 seconds. It needs that server's relay password (on a LogiKast server: Server › Relay). Turning this on, changing it or turning it off needs a server restart, which disconnects your encoders and listeners for a few seconds.")
        }
    }

    private struct MasterCheckKey: Equatable { var master: MasterRelay; var ownInstance: String? }

    /// Checks the other server once the settings stop changing, then every 20 seconds while this page is open.
    private func watchMaster() async {
        masterResult = nil
        let m = model.config.server.masterRelay
        guard m.isActive, (1...65535).contains(m.port) else { masterChecking = false; return }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }     // tests make no network calls
        masterChecking = true
        try? await Task.sleep(nanoseconds: 800_000_000)
        while !Task.isCancelled {
            let result = await MasterProbe.probe(m, ownInstance: model.poller.status?.instanceUUID)
            guard !Task.isCancelled else { return }
            masterResult = result
            masterChecking = false
            try? await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }

    @ViewBuilder private func masterStatusRows(_ master: MasterRelay) -> some View {
        if masterChecking {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the server…").foregroundStyle(.secondary).font(.callout) }
        } else if let masterResult {
            switch masterResult {
            case .thisServer:
                Label("That is your own server. Enter a different one.", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            case .unreachable:
                Label("Can't reach \(master.server.trimmingCharacters(in: .whitespaces)):\(String(master.port)) from this Mac right now.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            case .badLogin:
                Label("The server answered, but not to that login. Check the relay user and password with whoever runs it.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            case .ok(let mounts):
                RelayedMountList(mounts: mounts, onDemand: master.onDemand)
            }
        }
    }

    @ViewBuilder private var alertsTab: some View {
            Section {
                Toggle("Send notifications", isOn: $model.config.notifications.enabled)
                if model.config.notifications.enabled {
                    Toggle("Encoder or relay connects or drops off", isOn: $model.config.notifications.encoderEvents)
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
                    Label("Notifications are turned off for LogiKast in System Settings, so no alerts can appear.", systemImage: "bell.slash")
                        .foregroundStyle(.orange).font(.callout)
                }
            } header: {
                Text("Alerts")
            } footer: {
                FooterText("Alerts need LogiKast to be running; it sits in the menu bar. Turn on \"Open LogiKast when I log in\" under App & Log to keep it there. The server itself keeps running without the app, but nobody is told if it has a problem.")
            }
    }

    @ViewBuilder private var appTab: some View {
            Section("App") {
                Text("The server runs in the background: it keeps running when you close or quit LogiKast, restarts if it stops unexpectedly, and starts when you log in. Use Stop Server to turn it off.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Open LogiKast when I log in", isOn: Binding(get: { model.loginItem.isEnabled }, set: { model.loginItem.set($0) }))
                if model.loginItem.needsApproval {
                    Button("Allow in Login Items Settings…") { model.loginItem.openSettings() }
                }
                if let err = model.loginItem.lastError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
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
                    Text("\(s.mounts.count) mount\(s.mounts.count == 1 ? "" : "s") live · \(s.totalListeners) listener\(s.totalListeners == 1 ? "" : "s")"
                         + (model.poller.bandwidth.map { r in let f = BandwidthRates.format(r.totalOut); return " · \(f.value) \(f.unit) out" } ?? ""))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.server.isEnabled {
                Button("Web Admin…") { model.openWebAdmin() }
                    .help("Opens Icecast's own admin pages in your browser, signed in with the admin user and password from the Setup tab.")
                Button("Restart Server…") { model.promptForRestart() }
            }
        }
    }

    private var statusText: String {
        switch model.server.state {
        case .stopped: "Server is off"
        case .running: model.poller.reachable ? "Server is running" : "Server is starting…"
        case .needsApproval: "Allow LogiKast in System Settings › Login Items to run the server in the background."
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
    /// What changes for people and programs using the current password; shown before a new one is generated.
    var consequence = ""
    @State private var revealed = false
    @State private var copied = false
    @State private var confirmGenerate = false

    var body: some View {
        LabeledContent(label) {
            HStack {
                Group {
                    if revealed { TextField("", text: $value) } else { SecureField("", text: $value) }
                }
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 200)
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help(revealed ? "Hide" : "Show")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy").disabled(value.isEmpty)
                Button { confirmGenerate = true } label: { Image(systemName: "dice") }
                    .buttonStyle(.borderless).help("Generate a new random password…")
            }
        }
        .confirmationDialog("Generate a new \(label.lowercased())?", isPresented: $confirmGenerate, titleVisibility: .visible) {
            Button("Generate New Password", role: .destructive) { value = Password.random() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current password, and the old one can't be brought back. " + consequence)
        }
    }
}

/// Updates section of App & Log: automatic checks, the beta switch, and a manual check.
struct UpdateSettings: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
            Toggle("Include beta versions", isOn: $updater.includeBetas)
            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                Spacer()
                if let last = updater.lastCheck {
                    Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.system(size: FooterText.fontSize)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            FooterText("Beta versions arrive earlier and may have rough edges. Turn this off to receive final releases only.")
        }
    }
}
