import SwiftUI

enum SidebarSelection: Hashable {
    case server
    case mount(UUID)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarSelection? = .server

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
        .onAppear {   // lets scripted checks open straight to a mount page
            if CommandLine.arguments.contains("--show-mount"), let m = model.config.mounts.first {
                selection = .mount(m.id)
            }
        }
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
