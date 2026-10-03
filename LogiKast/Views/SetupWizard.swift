import SwiftUI

enum WizardStep: Int, CaseIterable {
    case welcome, station, network, listeners, encoder

    var title: String {
        switch self {
        case .welcome: "Welcome to LogiKast"
        case .station: "Your station"
        case .network: "Network"
        case .listeners: "Listeners"
        case .encoder: "Connect your encoder"
        }
    }
}

struct SetupWizard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step: WizardStep
    @State private var draft = AppConfig()
    @State private var audience = SetupAudience.thisMac
    @State private var bitrate = 64
    @State private var portStatus = PortStatus.available
    @State private var loaded = false

    /// True when opened on a station that is already set up: warns, and confirms changes before saving.
    let isRerun: Bool
    @State private var pendingChanges: [SetupChange] = []
    @State private var confirmChanges = false

    init(initialStep: WizardStep = .welcome, isRerun: Bool = false) {
        _step = State(initialValue: initialStep)
        self.isRerun = isRerun
    }

    private var ownPort: Int? { model.server.isEnabled ? model.config.server.port : nil }
    private var mountBinding: Binding<Mount> { $draft.mounts[0] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .welcome: WelcomeStep(isRerun: isRerun, mounts: model.config.mounts.map(\.name))
                case .station: stationStep
                case .network: networkStep
                case .listeners: listenersStep
                case .encoder: EncoderStep(config: draft, onRestart: { commit(); model.confirmRestart() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: 640, height: 650)
        .onAppear(perform: load)
        .alert("Change your existing station?", isPresented: $confirmChanges) {
            Button("Apply Changes", role: pendingChanges.contains { $0.disruptive } ? .destructive : nil) {
                commit(); applyIfRunning(); step = .encoder
            }
            Button("Go Back", role: .cancel) {}
        } message: {
            Text(changeSummary)
        }
    }

    private var changeSummary: String {
        var lines = pendingChanges.map { "• \($0.text)\($0.disruptive ? "  ⚠︎" : "")" }
        if pendingChanges.contains(where: { $0.disruptive }) {
            lines.append("\n⚠︎ These changes can disconnect listeners and encoders; encoders may need new settings.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Chrome

    private var header: some View {
        VStack(spacing: 10) {
            Text(step.title).font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(WizardStep.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: s == step ? 28 : 16, height: 6)
                }
            }
        }
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            if step == .welcome {
                Button(isRerun ? "Cancel" : "Skip Setup") { finish(skip: true) }
            } else {
                Button("Back") { go(-1) }
            }
            Spacer()
            if step == .encoder {
                Button("Done") { finish(skip: false) }.keyboardShortcut(.defaultAction)
            } else {
                Button(step == .welcome ? "Get Started" : "Continue") { go(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(16)
    }

    private var canContinue: Bool {
        switch step {
        case .network: portStatus == .available && ConfigValidator.issues(for: draft).allSatisfy { $0.severity != .error || $0.mountID != nil }
        case .station: ConfigValidator.issues(for: draft).filter { $0.mountID != nil && $0.severity == .error }.isEmpty
        default: true
        }
    }

    // MARK: Steps

    private var stationStep: some View {
        Form {
            Section {
                LabeledContent("Station name") { TextField("", text: mountBinding.streamName, prompt: Text("e.g. My Radio Station")).multilineTextAlignment(.trailing) }
                DescriptionField(text: mountBinding.streamDescription, prompt: "e.g. Classic hits, all day")
                LabeledContent("Genre") { TextField("", text: mountBinding.genre, prompt: Text("e.g. Variety")).multilineTextAlignment(.trailing) }
                LabeledContent("Website") { TextField("", text: mountBinding.streamURL, prompt: Text("https://")).multilineTextAlignment(.trailing) }
            } header: {
                Text("What listeners see")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This is shown to listeners and in directories. You can change it any time.")
                    LinkedText(markdown: Encoders.streamInfoNote, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
                }
            }
            Section {
                DisclosureGroup("Advanced") {
                    LabeledContent("Mount name") { TextField("", text: mountBinding.name, prompt: Text("/live")).multilineTextAlignment(.trailing) }
                    Text("The mount is the end of your listen link, like /live. Most people keep the default.")
                        .font(.callout).foregroundStyle(.secondary)
                    IssuesView(issues: ConfigValidator.issues(for: draft).filter { $0.mountID != nil })
                }
            }
        }
        .formStyle(.grouped)
    }

    private var networkStep: some View {
        Form {
            Section {
                IntField(title: "Port", value: $draft.server.port)
                    .onChange(of: draft.server.port) { _ in refreshPort() }
                portMessage
            } header: {
                Text("Port")
            } footer: {
                Text("Listeners and encoders reach your server through this number. 8000 is the usual choice.")
            }

            Section {
                Picker("Who can listen?", selection: $audience) {
                    Text("Only this Mac (for testing)").tag(SetupAudience.thisMac)
                    Text("Anyone — my network and the internet").tag(SetupAudience.anyone)
                }
                .pickerStyle(.radioGroup)

                if audience == .anyone {
                    LabeledContent("Your station's address") {
                        TextField("", text: $draft.server.hostname, prompt: Text("e.g. mystation.example.com"))
                            .multilineTextAlignment(.trailing)
                    }
                    if let ip = NetworkInfo.lanIPv4Addresses().first {
                        HStack {
                            Text("This Mac on your network: \(ip)").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Use This Address") { draft.server.hostname = ip }
                        }
                    }
                    Text("Listeners on your own network can use the address above. For people on the internet, your router must forward port \(String(draft.server.port)) to this Mac, and the address should be your public IP or domain name. If macOS asks whether to allow incoming connections, choose Allow.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Audience")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var portMessage: some View {
        switch portStatus {
        case .available:
            Label("Port \(String(draft.server.port)) is available.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .inUse:
            HStack {
                Label("Port \(String(draft.server.port)) is already used by another app on this Mac.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Spacer()
                if let p = SetupLogic.suggestPort(preferred: 8000, ownPort: ownPort, isInUse: PortCheck.isInUse(port:)) {
                    Button("Use \(p)") { draft.server.port = p }
                }
            }
        case .tooLow:
            Label("Use a port of 1024 or higher.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .invalid:
            Label("Enter a port between 1024 and 65535.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var listenersStep: some View {
        Form {
            Section {
                Picker("Most listeners at once", selection: $draft.server.maxClients) {
                    ForEach(SetupLogic.listenerPresets, id: \.self) { Text("\($0)").tag($0) }
                    if !SetupLogic.listenerPresets.contains(draft.server.maxClients) {
                        Text("\(draft.server.maxClients)").tag(draft.server.maxClients)
                    }
                }
                Picker("Your stream's bitrate", selection: $bitrate) {
                    ForEach(SetupLogic.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
            } footer: {
                Text("Extra listeners are turned away politely once the limit is reached. The bitrate is set in your encoder; it's only used here for the estimate below.")
            }

            Section("Internet speed you need") {
                let mbps = SetupLogic.uploadMbps(listeners: draft.server.maxClients, kbps: bitrate)
                HStack {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.accentColor).font(.title2)
                    VStack(alignment: .leading) {
                        Text("About \(SetupLogic.describe(mbps: mbps)) of upload speed").font(.headline)
                        Text("for \(draft.server.maxClients) listeners at \(bitrate) kbps")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Upload speed is usually lower than the download speed you pay for. Run a speed test on your connection, and pick a listener limit your upload can carry. Listeners on your own network don't use your internet connection.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        draft = SetupLogic.ensureMount(model.config)
        audience = SetupAudience(bindAddress: draft.server.bindAddress)
        if !model.server.isEnabled, PortCheck.isInUse(port: draft.server.port),
           let p = SetupLogic.suggestPort(preferred: draft.server.port, isInUse: PortCheck.isInUse(port:)) {
            draft.server.port = p          // new install on a busy default port: pick a free one
        }
        refreshPort()
    }

    private func refreshPort() {
        portStatus = SetupLogic.status(port: draft.server.port, ownPort: ownPort, isInUse: PortCheck.isInUse(port:))
    }

    private func go(_ delta: Int) {
        guard let next = WizardStep(rawValue: step.rawValue + delta) else { return }
        if next == .encoder {
            if isRerun {
                let changes = SetupLogic.changes(from: model.config, to: committedConfig())
                if !changes.isEmpty {
                    pendingChanges = changes
                    confirmChanges = true
                    return                      // stays put until the user confirms
                }
            } else {
                commit(); applyIfRunning()
            }
        }
        step = next
    }

    /// The configuration the draft would produce, without saving it.
    private func committedConfig() -> AppConfig {
        var c = draft
        c.server.bindAddress = audience.bindAddress
        if audience == .thisMac { c.server.hostname = "localhost" }
        if c.server.hostname.trimmingCharacters(in: .whitespaces).isEmpty { c.server.hostname = "localhost" }
        c.setupCompleted = true
        return c
    }

    /// Saves the draft as the app's configuration.
    private func commit() {
        let c = committedConfig()
        draft = c
        model.config = c
    }

    /// Settings that don't need a restart are applied to an already-running server straight away.
    private func applyIfRunning() {
        guard model.server.isEnabled, !model.server.requiresRestart(for: model.config) else { return }
        model.server.apply(config: model.config)
    }

    private func finish(skip: Bool) {
        if skip {
            if !isRerun { model.config.setupCompleted = true }   // a re-run Cancel changes nothing
        } else {
            commit()
            applyIfRunning()
        }
        dismiss()
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var isRerun = false
    var mounts: [String] = []

    var body: some View {
        VStack(spacing: isRerun ? 14 : 22) {
            if isRerun {
                VStack(alignment: .leading, spacing: 6) {
                    Label("You already have a station set up", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text("This assistant is for first-time setup. It changes your server settings and your first mount (\(mounts.first ?? "/live")), and encoders using a mount you rename will be disconnected. To add another stream, cancel and use the + button above the mount list. Nothing is saved until you confirm at the end.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
            }
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: isRerun ? 56 : 96, height: isRerun ? 56 : 96)
            Text("Let's get your station on the air.")
                .font(.title3)
            VStack(alignment: .leading, spacing: 14) {
                row("1.circle.fill", "Name your station", "What listeners see.")
                row("2.circle.fill", "Choose how people connect", "Port and who can listen.")
                row("3.circle.fill", "Set your listener limit", "And see the internet speed it needs.")
                row("4.circle.fill", "Connect your encoder", "An encoder app such as \(Encoders.linkedList) sends your audio here.")
            }
            .frame(maxWidth: 600)
            Text("LogiKast runs the server in the background after quitting this app.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.top, isRerun ? 12 : 24)
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                LinkedText(markdown: detail, color: .secondaryLabelColor)
            }
        }
    }
}

// MARK: - Encoder / go live

private struct EncoderStep: View {
    @EnvironmentObject var model: AppModel
    let config: AppConfig
    var onRestart: () -> Void

    private var mount: Mount { config.mounts[0] }
    private var live: MountStatus? { model.status(for: mount) }
    private var host: String { config.server.hostname.isEmpty ? "localhost" : config.server.hostname }

    var body: some View {
        Form {
            Section("1. Start the server") {
                HStack {
                    StatusDot(color: serverColor)
                    Text(serverText)
                    Spacer()
                    if model.server.isEnabled {
                        if model.server.requiresRestart(for: model.config) {
                            Button("Restart Server", action: onRestart)
                        }
                    } else {
                        Button("Start Server") { model.startServer() }.disabled(!model.canStart)
                    }
                }
            }

            Section {
                CopyableRow(label: "Address", value: host)
                CopyableRow(label: "Port", value: String(config.server.port))
                CopyableRow(label: "Mount", value: mount.name)
                CopyableRow(label: "Username", value: "source")
                CopyableRow(label: "Password", value: config.server.sourcePassword, secret: true)
            } header: {
                Text("2. Enter these in your encoder")
            } footer: {
                LinkedText(markdown: "Choose “Icecast” as the server type. The username is always “source”. Format and bitrate are chosen in your encoder. Need one? Get \(Encoders.linkedList).", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            }

            Section("3. Check the connection") {
                if let s = live {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Your encoder is connected — you're on the air!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.headline)
                        Text(details(of: s)).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.server.isEnabled ? "Waiting for your encoder to connect…" : "Start the server, then connect your encoder.")
                            .foregroundStyle(.secondary)
                    }
                }
                CopyableRow(label: "Listen link", value: "http://\(host):\(config.server.port)\(mount.name)")
            }
        }
        .formStyle(.grouped)
    }

    private func details(of s: MountStatus) -> String {
        var parts: [String] = []
        if let f = s.contentType.flatMap(StreamFormat.init(contentType:)) { parts.append(f.label) }
        if let b = s.bitrate { parts.append("\(b) kbps") }
        if let n = s.streamName { parts.append(n) }
        parts.append("\(s.listeners) listener\(s.listeners == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    private var serverText: String {
        switch model.server.state {
        case .stopped: "The server is off."
        case .running: model.poller.reachable ? "The server is running." : "The server is starting…"
        case .needsApproval: "Allow LogiKast in System Settings › Login Items."
        case .failed(let m): m
        }
    }

    private var serverColor: Color {
        switch model.server.state {
        case .stopped: .gray
        case .running: model.poller.reachable ? .green : .orange
        case .needsApproval: .orange
        case .failed: .red
        }
    }
}
