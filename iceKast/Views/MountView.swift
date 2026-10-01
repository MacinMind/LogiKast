import SwiftUI

struct MountView: View {
    @EnvironmentObject var model: AppModel
    @Binding var mount: Mount
    var onDelete: () -> Void
    @State private var confirmDelete = false

    private var status: MountStatus? { model.status(for: mount) }
    private var host: String { model.config.server.hostname.isEmpty ? "localhost" : model.config.server.hostname }
    private var port: Int { model.config.server.port }

    var body: some View {
        Form {
            Section {
                statusCard
                IssuesView(issues: model.issues.filter { $0.mountID == mount.id })
            }

            Section {
                CopyableRow(label: "Server type", value: "Icecast")
                CopyableRow(label: "Address", value: host)
                CopyableRow(label: "Port", value: String(port))
                CopyableRow(label: "Mount", value: mount.name)
                CopyableRow(label: "Username", value: "source")
                CopyableRow(label: "Password", value: mount.customPassword.isEmpty ? model.config.server.sourcePassword : mount.customPassword, secret: true)
                CopyableRow(label: "Format", value: mount.format.label)
            } header: {
                Text("Connect your encoder (BUTT, Audio Hijack, LadioCast, …)")
            } footer: {
                Text("The username is always “source” (lowercase) — type it exactly like that in your encoder. The password is the encoder password.")
            }

            Section("Listen link") {
                CopyableRow(label: "URL", value: "http://\(host):\(port)\(mount.name)")
                ForEach(NetworkInfo.lanIPv4Addresses(), id: \.self) { ip in
                    CopyableRow(label: "On your network", value: "http://\(ip):\(port)\(mount.name)")
                }
            }

            Section("Mount") {
                LabeledContent("Mount name") {
                    TextField("", text: $mount.name, prompt: Text("/live")).multilineTextAlignment(.trailing)
                }
                Picker("Format", selection: $mount.format) {
                    ForEach(StreamFormat.allCases) { Text($0.label).tag($0) }
                }
                IntField(title: "Max listeners (0 = no limit)", value: $mount.maxListeners)
                IntField(title: "Burst size", value: $mount.burstSize, suffix: "bytes")
                LabeledContent("Fallback mount") {
                    TextField("", text: $mount.fallbackMount, prompt: Text("None")).multilineTextAlignment(.trailing)
                }
                if !mount.fallbackMount.isEmpty {
                    Toggle("Return listeners when this stream comes back", isOn: $mount.fallbackOverride)
                }
                LabeledContent("Own encoder password") {
                    TextField("", text: $mount.customPassword, prompt: Text("Use server password")).multilineTextAlignment(.trailing)
                }
            }

            Section {
                LabeledContent("Name") { TextField("", text: $mount.streamName, prompt: Text(status?.streamName ?? "e.g. My Radio Station")).multilineTextAlignment(.trailing) }
                LabeledContent("Description") { TextField("", text: $mount.streamDescription, prompt: Text(status?.streamDescription ?? "e.g. Classic hits, all day")).multilineTextAlignment(.trailing) }
                LabeledContent("Genre") { TextField("", text: $mount.genre, prompt: Text(status?.genre ?? "e.g. Variety")).multilineTextAlignment(.trailing) }
                LabeledContent("Website") { TextField("", text: $mount.streamURL, prompt: Text(status?.streamURL ?? "https://")).multilineTextAlignment(.trailing) }
                if let s = status, hasEncoderInfo(s) {
                    Button("Copy Encoder's Info Into These Fields") { copyEncoderInfo(s) }
                        .help("Saves what your encoder is sending here, so it stays even if the encoder stops sending it")
                }
                Toggle("List in public directory", isOn: $mount.isPublic)
            } header: {
                Text("Stream info")
            } footer: {
                Text(status != nil
                     ? "Grey text is what your encoder is sending right now, and listeners see it. Type here only to override it."
                     : "What listeners and directories see about this stream. Leave a field blank to use whatever your encoder sends; anything you enter here replaces the encoder's value.")
            }

            Section {
                Button("Delete Mount…", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mount.name)
        .confirmationDialog("Delete \(mount.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Connected listeners and encoders on this mount will be dropped the next time you apply changes.")
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

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    StatusDot(color: status != nil ? .green : .gray)
                    Text(status != nil ? "On air" : (model.server.isEnabled ? "Waiting for encoder" : "Server is off"))
                        .font(.headline)
                }
                if let title = status?.title {
                    Text(title).foregroundStyle(.secondary).lineLimit(2)
                }
                if let s = status, let line = encoderLine(s) {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                if let s = status, let sent = s.contentType.flatMap(StreamFormat.init(contentType:)), sent != mount.format {
                    HStack {
                        Label("Encoder is sending \(sent.label), but this mount is set to \(mount.format.label).", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                        Button("Switch mount to \(sent.label)") { mount.format = sent }
                    }
                }
            }
            Spacer()
            if let s = status {
                stat("Listeners", "\(s.listeners)")
                stat("Peak", "\(s.peak)")
                if let since = s.streamStart {
                    VStack(alignment: .trailing) {
                        Text("On air since").font(.caption).foregroundStyle(.secondary)
                        Text(since, style: .relative).monospacedDigit()
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
        }
    }
}
