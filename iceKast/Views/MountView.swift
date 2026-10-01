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

            Section("Connect your encoder (BUTT, Audio Hijack, LadioCast, …)") {
                CopyableRow(label: "Server type", value: "Icecast")
                CopyableRow(label: "Address", value: host)
                CopyableRow(label: "Port", value: String(port))
                CopyableRow(label: "Mount", value: mount.name)
                CopyableRow(label: "User", value: "source")
                CopyableRow(label: "Password", value: mount.customPassword.isEmpty ? model.config.server.sourcePassword : mount.customPassword, secret: true)
                CopyableRow(label: "Format", value: mount.format.label)
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

            Section("Stream info") {
                LabeledContent("Name") { TextField("", text: $mount.streamName).multilineTextAlignment(.trailing) }
                LabeledContent("Description") { TextField("", text: $mount.streamDescription).multilineTextAlignment(.trailing) }
                LabeledContent("Genre") { TextField("", text: $mount.genre).multilineTextAlignment(.trailing) }
                LabeledContent("Website") { TextField("", text: $mount.streamURL).multilineTextAlignment(.trailing) }
                Toggle("List in public directory", isOn: $mount.isPublic)
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
