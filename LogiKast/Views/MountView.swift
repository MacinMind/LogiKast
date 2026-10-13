import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MountView: View {
    @EnvironmentObject var model: AppModel
    @Binding var mount: Mount
    @State private var dropMode = DropMode.nothing
    @State private var backupError: String?
    @State private var backupNotice: String?
    @State private var backupAudio: (text: String, info: BackupConverter.Info)?
    @State private var conversion: ConversionJob?
    @State private var backupDropTargeted = false
    @State private var nameAtOpen = ""
    enum DropMode: Hashable { case nothing, file, relay, mount }

    private var status: MountStatus? { model.status(for: mount) }
    private var host: String { model.config.server.hostname.isEmpty ? "localhost" : model.config.server.hostname }
    private var port: Int { model.config.server.port }
    private var share: ShareLinks {
        ShareLinks(host: host, port: port, mount: mount.name, title: mount.streamName.isEmpty ? (status?.streamName ?? "") : mount.streamName)
    }

    var body: some View {
        VStack(spacing: 0) {
            StatusPanel {
                statusCard
                IssuesView(issues: model.issues.filter { $0.mountID == mount.id })
                if model.hasPendingChanges { PendingChangesBanner() }
            }
            SegmentedTabs(selection: $model.mountTab)
            if model.mountTab == .connect { mountNameCard }
            if model.mountTab == .listeners {
                ListenersSection(mount: mount)      // a table, not a Form: it has to stay fast with thousands of rows
            } else {
                Form { tabContent }
                    .formStyle(.grouped)
                    .onDrop(of: [.fileURL], isTargeted: $backupDropTargeted, perform: dropBackup)
                    .overlay { if backupDropTargeted && model.mountTab == .backup && conversion == nil { BackupDropHint() } }
            }
        }
        .onAppear {
            nameAtOpen = mount.name
            dropMode = !mount.backupFile.isEmpty ? .file : (mount.backupIsRelay ? .relay : (!mount.fallbackMount.isEmpty ? .mount : .nothing))
        }
        .onChange(of: dropMode) { newMode in
            // Switching away from a choice clears it, so the saved settings match what is shown.
            if newMode != .file, !mount.backupFile.isEmpty { removeBackup() }
            if newMode != .mount, !mount.fallbackMount.isEmpty { mount.fallbackMount = "" }
            mount.backupIsRelay = newMode == .relay
        }
    }

    /// The one editable thing on the Connect tab. Lives outside the Form so it can span the full width.
    private var mountNameCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor)
                Text("Mount name").font(.headline)
                Spacer()
                Picker("Audio from", selection: $mount.isRelay) {
                    Text("An encoder").tag(false)
                    Text("Another Icecast server").tag(true)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Where this stream's audio comes from: an encoder app connected to this server, or a stream relayed from another Icecast server.")
            }
            TextField("", text: $mount.name, prompt: Text("/live"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .autocorrectionDisabled()
            HStack(spacing: 4) {
                Text("Your stream's address:").foregroundStyle(.secondary)
                Text(share.listenURL).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            .font(.callout)
            if model.server.isEnabled, !nameAtOpen.isEmpty, mount.name != nameAtOpen {
                Label("Renaming a stream that's on the air disconnects its encoder. After you apply the change, enter the new mount name in your encoder.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
            Text(mount.isRelay
                 ? "The mount name is what your listeners use, like /live or /jazz. Each stream on your server needs its own. Add more with the + button above the mount list."
                 : "The mount name identifies this stream, like /live or /jazz. Listeners and your encoder both use it, so each stream needs its own. Add more with the + button above the mount list.")
                .font(.system(size: FooterText.fontSize)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    @ViewBuilder private var tabContent: some View {
        switch model.mountTab {
        case .connect: connectSection
        case .share: shareSection
        case .listeners: EmptyView()
        case .streamInfo: streamInfoSection
        case .backup: backupSection
        case .advanced: advancedSections
        }
    }

    @ViewBuilder private var connectSection: some View {
        if mount.isRelay { relaySourceSection } else { encoderSection }
    }

    @ViewBuilder private var relaySourceSection: some View {
        Section {
            RelayEditor(relay: $mount.relay)
        } header: {
            Text("Relay from another Icecast server")
        } footer: {
            FooterText("No encoder is needed. LogiKast takes the stream from the server above and passes it to your listeners. If it can't be reached, the mount waits and retries every few seconds. Shoutcast servers use / as the mount.")
        }
    }

    @ViewBuilder private var encoderSection: some View {
        Section {
            CopyableRow(label: "Server type", value: "Icecast")
            CopyableRow(label: "Address", value: host)
            CopyableRow(label: "Port", value: String(port))
            CopyableRow(label: "Mount", value: mount.name)
            CopyableRow(label: "Username", value: "source")
            CopyableRow(label: "Password", value: mount.customPassword.isEmpty ? model.config.server.sourcePassword : mount.customPassword, secret: true)
        } header: {
            LinkedText(markdown: "Connect your encoder (\(Encoders.linkedList))", font: .systemFont(ofSize: 13, weight: .semibold))
        } footer: {
            FooterText("These are filled in for you: copy them into your encoder. The username is always “source” (lowercase). Format and bitrate are chosen in your encoder; LogiKast detects them once it connects.")
        }
    }

    @ViewBuilder private var shareSection: some View {
            Section {
                CopyableRow(label: "Listen link", value: share.listenURL)
                CopyableRow(label: "Playlist (.m3u)", value: share.playlistURL)
                ForEach(NetworkInfo.lanIPv4Addresses(), id: \.self) { ip in
                    CopyableRow(label: "On your network", value: "http://\(ip):\(port)\(mount.name)")
                }
                if DirectoryListing.isPrivateHost(host) {
                    Label("For listeners outside your network, set a Public host name under Server › Setup.",
                          systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
                }
                SharePlayerView(share: share)
                QRShareView(url: share.listenURL, mountName: mount.name)
            } header: {
                Text("Share your stream")
            } footer: {
                FooterText(ShareLinks.httpsNote)
            }
    }

    @ViewBuilder private var backupSection: some View {
            Section {
                Picker("", selection: $dropMode) {
                    Text("Nothing — listeners hear silence").tag(DropMode.nothing)
                    Text("Play a backup audio file").tag(DropMode.file)
                    Text("Switch listeners to a stream from another Icecast server").tag(DropMode.relay)
                    Text("Switch listeners to another mount on this server").tag(DropMode.mount)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                switch dropMode {
                case .nothing:
                    EmptyView()
                case .file:
                    backupFileRows
                case .relay:
                    RelayEditor(relay: $mount.backupRelay)
                    backupRelayStatus
                case .mount:
                    LabeledContent("Other stream's mount") {
                        TextField("", text: $mount.fallbackMount, prompt: Text("e.g. /backup")).multilineTextAlignment(.trailing)
                    }
                    Toggle("Return listeners when this stream comes back", isOn: $mount.fallbackOverride)
                }
            } header: {
                Text(mount.isRelay ? "When the relayed stream drops off" : "When the encoder drops off")
            } footer: {
                FooterText(mount.isRelay
                           ? "Listeners keep hearing something instead of silence, and move back to the relayed stream automatically when it returns."
                           : "Listeners keep hearing something instead of silence, and move back to the live stream automatically when your encoder reconnects.")
            }
    }

    @ViewBuilder private var streamInfoSection: some View {
            Section {
                LabeledContent("Name") { TextField("", text: $mount.streamName, prompt: Text(status?.streamName ?? "e.g. My Radio Station")).multilineTextAlignment(.trailing) }
                DescriptionField(text: $mount.streamDescription, prompt: status?.streamDescription ?? "e.g. Classic hits, all day")
                LabeledContent("Genre") { TextField("", text: $mount.genre, prompt: Text(status?.genre ?? "e.g. Variety")).multilineTextAlignment(.trailing) }
                LabeledContent("Website") { TextField("", text: $mount.streamURL, prompt: Text(status?.streamURL ?? "https://")).multilineTextAlignment(.trailing) }
                if let s = status, hasEncoderInfo(s), !mount.isRelay {
                    Button("Copy Encoder's Info Into These Fields") { copyEncoderInfo(s) }
                        .help("Saves what your encoder is sending here, so it stays even if the encoder stops sending it")
                }
                Toggle("List in public directory", isOn: $mount.isPublic)
                if mount.isPublic {
                    LabeledContent("Contact email") {
                        TextField("", text: $model.config.server.adminEmail, prompt: Text("you@example.com")).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Station address") {
                        TextField("", text: $model.config.server.hostname, prompt: Text("e.g. mystation.example.com")).multilineTextAlignment(.trailing)
                    }
                    ForEach(DirectoryListing.problems(for: model.config), id: \.self) { p in
                        Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }
                    if mount.streamDescription.isEmpty && status?.streamDescription == nil {
                        Label("Tip: add a description above. Directories show \"Unspecified description\" otherwise.", systemImage: "lightbulb")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    if DirectoryListing.problems(for: model.config).isEmpty {
                        Label("Ready: this stream will be listed in the Xiph directory about a minute after it goes on the air. Your router must forward port \(String(model.config.server.port)) to this Mac for listeners to reach it.",
                              systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    }
                }
            } header: {
                Text("Stream info")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    // Each sentence on its own line, so a wrap never splits one oddly.
                    if status != nil {
                        FooterText("Gray text is what your encoder is sending right now, and listeners see it.")
                        FooterText("Type here only to override it.")
                    } else {
                        FooterText("What listeners and directories see about this stream.")
                        FooterText("Anything you enter here replaces the encoder's value.")
                    }
                    LinkedText(markdown: Encoders.streamInfoNote, font: .systemFont(ofSize: FooterText.fontSize), color: .secondaryLabelColor)
                }
            }
    }

    @ViewBuilder private var advancedSections: some View {
            Section("Mount settings") {
                IntField(title: "Max listeners (0 = no limit)", value: $mount.maxListeners)
                IntField(title: "Burst size", value: $mount.burstSize, suffix: "bytes")
                if !mount.isRelay {
                    LabeledContent("Own encoder password") {
                        TextField("", text: $mount.customPassword, prompt: Text("Use server password")).multilineTextAlignment(.trailing)
                    }
                }
            }

            Section {
                CopyableRow(label: "Server", value: host)
                CopyableRow(label: "Port", value: String(port))
                CopyableRow(label: "Mount", value: mount.name)
            } header: {
                Text("Relaying by other servers")
            } footer: {
                FooterText("Another Icecast server can relay this stream with these, and needs no password. Each relay counts as one listener. To let a server relay all your mounts at once, see Server › Relay.")
            }
    }

    /// Whether the other server's stream (the backup) is connected.
    @ViewBuilder private var backupRelayStatus: some View {
        let connected = model.poller.status?.backupMounts.contains { $0.path == BackupAudio.internalMount(forMount: mount.name) } ?? false
        if !model.server.isEnabled {
            Label("The backup starts working when the server is on.", systemImage: "moon.zzz").foregroundStyle(.secondary).font(.callout)
        } else if model.hasPendingChanges {
            Label("Apply your changes to start the backup.", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.callout)
        } else if connected {
            Label("Ready. Listeners move to it if this stream drops off.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        } else if mount.backupRelay.onDemand {
            Label("Ready. It connects when this stream drops off, which takes a few seconds.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        } else if mount.backupRelay.isSet {
            Label("Waiting for the other server.", systemImage: "clock").foregroundStyle(.secondary).font(.callout)
        }
        let listening = model.poller.status?.backupListeners(forMount: mount.name) ?? 0
        if listening > 0 {
            Label("\(listening) listener\(listening == 1 ? " is" : "s are") hearing your backup right now.", systemImage: "headphones").font(.callout)
        }
    }


    private func encoderLine(_ s: MountStatus) -> String? {
        var parts: [String] = []
        if let f = s.contentType.flatMap(StreamFormat.init(contentType:)) { parts.append(f.label) }
        if let b = s.bitrate { parts.append("\(b) kbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func hasEncoderInfo(_ s: MountStatus) -> Bool {
        s.streamName != nil || s.genre != nil || s.streamURL != nil || s.streamDescription != nil
    }

    private func copyEncoderInfo(_ s: MountStatus) {
        if let v = s.streamName { mount.streamName = v }
        if let v = s.genre { mount.genre = v }
        if let v = s.streamURL { mount.streamURL = v }
        if let v = s.streamDescription { mount.streamDescription = v }
    }

    /// The live stream's format, when there is one to copy.
    private var liveTarget: BackupTarget? { status.flatMap(BackupTarget.matching) }

    @ViewBuilder private var backupFileRows: some View {
        if let job = conversion {
            ConversionRow(job: job)
        } else if mount.backupFile.isEmpty {
            HStack {
                Button("Choose Audio File…", action: chooseBackup)
                Text("or drag a file here. Any audio file works; LogiKast converts it if needed.").foregroundStyle(.secondary).font(.callout)
                Spacer()
            }
        } else {
            HStack {
                Image(systemName: "waveform").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text(mount.backupName.isEmpty ? mount.backupFile : mount.backupName)
                    Text(backupAudio?.text ?? BackupAudio.kind(ofStored: mount.backupFile)?.label ?? "Audio")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Replace…", action: chooseBackup)
                Button("Remove") { removeBackup() }
            }
        }
        if let backupNotice {
            Label(backupNotice, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary).font(.callout)
        }
        if conversion == nil, let warning = backupMismatch, let live = liveTarget {
            HStack {
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                Spacer()
                Button("Convert to Match") { reconvertBackup(to: live) }
            }
        }
        if let backupError {
            Label(backupError, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
        }
        backupStatusRows
        Text("The file plays in a loop at normal speed whenever your encoder is away, and listeners switch back to the live stream within a few seconds of it returning. LogiKast converts the file to your live stream's format, so the switch is smooth.")
            .font(.callout).foregroundStyle(.secondary)
            .task(id: mount.backupFile) { await loadBackupInfo() }
    }

    /// Why the stored backup doesn't match the live stream, or nil when it does (or there is nothing to compare).
    private var backupMismatch: String? {
        guard let live = liveTarget, let kind = BackupAudio.kind(ofStored: mount.backupFile) else { return nil }
        let he = BackupAudio.isHighEfficiency(mount.backupFile)
        let have = he ? "HE-AAC" : kind.label
        if kind != live.kind || (kind == .aac && he != live.highEfficiency) {
            return "Your live stream is \(live.formatLabel) but this backup is \(have). Players stop when the stream switches to a different format."
        }
        guard let info = backupAudio?.info else { return nil }
        let rate = Int(info.sampleRate.rounded())
        if rate != live.sampleRate || info.channels != live.channels {
            return "Your live stream is \(BackupAudio.rateText(live.sampleRate)) \(live.channels == 1 ? "mono" : "stereo"), but this backup is \(BackupAudio.rateText(rate)) \(info.channels == 1 ? "mono" : "stereo"). Players may glitch when the stream switches."
        }
        return nil
    }

    private func loadBackupInfo() async {
        let stored = mount.backupFile
        guard !stored.isEmpty else { backupAudio = nil; return }
        let loaded = await Task.detached(priority: .utility) { () -> (text: String, info: BackupConverter.Info)? in
            guard let text = BackupAudio.describe(stored: stored),
                  let info = BackupConverter.info(of: AppPaths.backupDir.appendingPathComponent(stored)) else { return nil }
            return (text, info)
        }.value
        if stored == mount.backupFile { backupAudio = loaded }
    }

    /// Whether the helper that plays the backup is ready, and who is hearing it right now.
    @ViewBuilder private var backupStatusRows: some View {
        let listening = model.poller.status?.backupListeners(forMount: mount.name) ?? 0
        switch model.backupState(for: mount) {
        case .notSet:
            EmptyView()
        case .serverOff:
            Label("The backup starts working when the server is on.", systemImage: "moon.zzz").foregroundStyle(.secondary).font(.callout)
        case .notRunning:
            HStack {
                Label("The backup audio helper isn't running yet. The server needs one restart to start it.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                Spacer()
                Button("Restart Server…") { model.promptForRestart(reason: "Backup audio needs the server restarted once so its helper can start.") }
            }
        case .notApplied:
            Label("Apply your changes to start the backup.", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.callout)
        case .starting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting the backup…").foregroundStyle(.secondary).font(.callout) }
        case .ready:
            Label("Ready. It plays automatically if your encoder drops off.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .problem(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
        }
        if listening > 0 {
            Label("\(listening) listener\(listening == 1 ? " is" : "s are") hearing your backup right now.", systemImage: "headphones")
                .font(.callout)
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose an audio file to play when your encoder drops off. If it isn't already in your stream's format, LogiKast converts it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addBackup(from: url)
    }

    /// A file dropped on the Backup tab becomes the backup, as if it had been chosen with the button.
    private func dropBackup(_ providers: [NSItemProvider]) -> Bool {
        guard model.mountTab == .backup, conversion == nil, let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), !url.hasDirectoryPath else { return }
            DispatchQueue.main.async {
                dropMode = .file
                addBackup(from: url)
            }
        }
        return true
    }

    private func addBackup(from url: URL) {
        let mountName = mount.name, target = liveTarget
        runBackupJob(name: url.lastPathComponent, target: target) { cancel, progress in
            try BackupAudio.install(from: url, mountName: mountName, target: target, cancel: cancel, progress: progress)
        }
    }

    private func reconvertBackup(to target: BackupTarget) {
        let mountName = mount.name, stored = mount.backupFile
        let display = mount.backupName.isEmpty ? mount.backupFile : mount.backupName
        runBackupJob(name: display, target: target) { cancel, progress in
            try BackupAudio.reconvert(stored: stored, displayName: display, mountName: mountName, target: target, cancel: cancel, progress: progress)
        }
    }

    /// Runs a copy or conversion off the main thread, showing progress, and applies the result to this mount.
    private func runBackupJob(name: String, target: BackupTarget?,
                              _ work: @escaping @Sendable (CancelFlag, @escaping (Double) -> Void) throws -> BackupAudio.Installed) {
        let job = ConversionJob(name: name)
        conversion = job
        backupError = nil
        backupNotice = nil
        let mountID = mount.id
        Task {
            do {
                let installed = try await Task.detached(priority: .userInitiated) {
                    try work(job.cancel) { f in job.report(f) }
                }.value
                if let i = model.config.mounts.firstIndex(where: { $0.id == mountID }) {
                    model.config.mounts[i].backupFile = installed.storedName
                    model.config.mounts[i].backupName = installed.displayName
                    model.config.mounts[i].fallbackMount = ""
                }
                if let t = installed.convertedTo {
                    backupNotice = target != nil
                        ? "Converted to \(t.summary) to match your live stream."
                        : "Converted to \(t.summary). Once your stream is on the air, LogiKast can convert it again to match."
                }
            } catch BackupAudio.BackupError.cancelled {
                // The user canceled: nothing changes.
            } catch {
                backupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            conversion = nil
        }
    }

    private func removeBackup() {
        BackupAudio.remove(mount.backupFile)
        mount.backupFile = ""
        mount.backupName = ""
        backupError = nil
        backupNotice = nil
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    StatusDot(color: status != nil ? .green : .gray)
                    Text(status != nil ? "On air" : (model.server.isEnabled ? (mount.isRelay ? (mount.relay.onDemand ? "Waiting for the first listener" : "Waiting for the other server") : "Waiting for encoder") : "Server is off"))
                        .font(.headline)
                }
                if let title = status?.title {
                    Text(title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(title)   // one line: the card keeps the same height whatever is playing
                }
                if let s = status, let line = encoderLine(s) {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .layoutPriority(1)       // the stream details get their room first; the number columns are compact
            Spacer(minLength: 8)
            if let s = status {
                // Fixed-width columns, so changing digits never move their neighbors. Out comes first: it
                // changes width most often (kb/s to Mb/s), and nothing to its right depends on it.
                let rate = model.poller.bandwidth?.outgoing(mount: mount.name).map(BandwidthRates.format)
                stat("Out \(rate?.unit ?? "kb/s")", rate?.value ?? "–", width: 58)
                    .help("Audio going out to listeners right now" + (model.poller.bandwidth?.into[mount.name].map { ". Encoder sending: \(BandwidthRates.format($0).value) \(BandwidthRates.format($0).unit)" } ?? ""))
                stat("Listeners", "\(s.listeners)", width: 56)
                stat("Peak", "\(s.peak)", width: 38)
                VStack(alignment: .trailing) {
                    Text("On air for").font(.caption).foregroundStyle(.secondary)
                    if let since = s.streamStart { Text(since, style: .relative).monospacedDigit() } else { Text("–") }
                }
                .frame(width: 100, alignment: .trailing)
            }
        }
    }

    private func stat(_ title: String, _ value: String, width: CGFloat) -> some View {
        VStack(alignment: .trailing) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(width: width, alignment: .trailing)
    }
}

/// A backup file being converted: its progress, and the Cancel switch.
final class ConversionJob: ObservableObject, @unchecked Sendable {
    let name: String
    let cancel = CancelFlag()
    @Published var fraction = 0.0
    private var lastShown = -1.0

    init(name: String) { self.name = name }

    /// Called from the converting thread; updates the window at most every 1%.
    func report(_ f: Double) {
        guard f - lastShown >= 0.01 || f >= 1 else { return }
        lastShown = f
        DispatchQueue.main.async { self.fraction = f }
    }
}

private struct ConversionRow: View {
    @ObservedObject var job: ConversionJob

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preparing “\(job.name)”…")
                ProgressView(value: job.fraction)
            }
            Button("Cancel") { job.cancel.cancel() }
        }
    }
}

/// Shown over the Backup tab while a file is dragged across it.
private struct BackupDropHint: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
            Label("Drop to use as your backup audio", systemImage: "waveform.badge.plus")
                .font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
        .background(Color.accentColor.opacity(0.08))
        .allowsHitTesting(false)
    }
}
