import SwiftUI

enum SidebarSelection: Hashable {
    case server
    case mount(UUID)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarSelection?

    init(initialSelection: SidebarSelection? = .server) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            switch selection {
            case .mount(let id):
                if let index = model.config.mounts.firstIndex(where: { $0.id == id }) {
                    MountView(mount: $model.config.mounts[index], onDelete: {
                        selection = .server
                        model.deleteMount(id)
                    })
                    .id(id)
                } else {
                    ServerView()
                }
            default:
                ServerView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ServerToggleButton() }
        }
        .sheet(isPresented: $model.showSetup) {
            SetupWizard(isRerun: model.setupIsRerun).environmentObject(model)
        }
        .confirmationDialog("LogiKast replaces iceKast", isPresented: $model.showLegacyPrompt, titleVisibility: .visible) {
            Button("Switch to LogiKast", role: .destructive) { model.switchFromLegacyServer() }
            Button("Not Now", role: .cancel) { model.keepLegacyServer() }
        } message: {
            Text("This app was called iceKast, and your server is still running under that name. Switching stops it and starts the same server (same settings) as LogiKast. Listeners and encoders disconnect for a few seconds, and most encoders reconnect by themselves.\n\nAfterward you can delete the old iceKast app.")
        }
        .confirmationDialog("Run the Setup Assistant again?", isPresented: $model.showSetupWarning, titleVisibility: .visible) {
            Button("Continue to Setup Assistant") { model.confirmSetupRerun() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.setupWarningMessage)
        }
        .confirmationDialog("Restart the server?",
                            isPresented: Binding(get: { model.restartPrompt != nil },
                                                 set: { if !$0 { model.restartPrompt = nil } }),
                            titleVisibility: .visible,
                            presenting: model.restartPrompt) { _ in
            Button("Restart Server", role: .destructive) { model.confirmRestart() }
            Button("Cancel", role: .cancel) { model.restartPrompt = nil }
        } message: { p in
            Text("\(p.reason)\n\n\(Self.impact(p)) Encoders have to reconnect — most do this automatically.")
        }
        .onAppear {   // lets scripted checks open straight to a mount page
            if CommandLine.arguments.contains("--show-mount"), let m = model.config.mounts.first {
                selection = .mount(m.id)
            }
        }
    }
}

extension ContentView {
    static func impact(_ p: AppModel.RestartPrompt) -> String {
        if p.listeners == 0 && p.encoders == 0 { return "Nobody is connected right now." }
        let l = "\(p.listeners) listener\(p.listeners == 1 ? "" : "s")"
        let e = "\(p.encoders) live stream\(p.encoders == 1 ? "" : "s")"
        return "\(l) and \(e) will be disconnected for a few seconds."
    }
}

struct ServerToggleButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.server.isEnabled {
            Button { model.stopServer() } label: { Label("Stop Server", systemImage: "stop.fill") }
        } else {
            Button { model.startServer() } label: { Label("Start Server", systemImage: "play.fill") }
                .disabled(!model.canStart)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Server") {
                HStack {
                    StatusDot(color: serverColor)
                    Text("Server")
                    Spacer()
                    Text(model.server.isEnabled ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
                .tag(SidebarSelection.server)
            }
            Section("Mounts") {
                ForEach(model.config.mounts) { mount in
                    let s = model.status(for: mount)
                    HStack {
                        StatusDot(color: s != nil ? .green : (model.server.isEnabled ? .orange : .gray))
                        Text(mount.name).lineLimit(1)
                        Spacer()
                        if let s {
                            Label("\(s.listeners)", systemImage: "headphones")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .tag(SidebarSelection.mount(mount.id))
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    selection = .mount(model.addMount().id)
                } label: { Label("Add Mount", systemImage: "plus") }
                .help("Add a mount point")
            }
        }
    }

    private var serverColor: Color {
        switch model.server.state {
        case .running: model.poller.reachable ? .green : .orange
        case .failed: .red
        case .needsApproval: .orange
        case .stopped: .gray
        }
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
}
