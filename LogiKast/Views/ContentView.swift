import SwiftUI

enum SidebarSelection: Hashable {
    case server
    case mount(UUID)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarSelection?
    /// The sidebar is how you move around, so it always stays open.
    @State private var columns = NavigationSplitViewVisibility.all

    init(initialSelection: SidebarSelection? = .server) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
                .modifier(NoSidebarToggle())
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
        .onChange(of: columns) { if $0 != .all { columns = .all } }
        .toolbar {
            HeaderToolbar(selection: selection)
            ToolbarItem(placement: .primaryAction) { ServerToggleButton() }
        }
        .modifier(NoSidebarToggle())
        .background(WindowSetup())
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

/// Starts or stops the whole server. Spelled out, because a bare play/stop icon doesn't say what it controls.
/// Start is the tinted, prominent button (Liquid Glass on macOS 26); Stop is the plain one with a red stop glyph.
struct ServerToggleButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.server.isEnabled {
            Button { model.stopServer() } label: {
                Label { Text("Stop Server") } icon: { Image(systemName: "stop.fill").foregroundStyle(.red) }
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
            }
            .help("Stop the server. Encoders and listeners are disconnected.")
        } else {
            Button { model.startServer() } label: {
                Label("Start Server", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
            }
            .modifier(ProminentToolbarStyle())
            .tint(.green)
            .disabled(!model.canStart)
            .help("Start the server")
        }
    }
}

struct ProminentToolbarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.borderedProminent) }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Server") {
                SidebarRow(color: serverColor, title: "Server", detail: serverDetail)
                    .tag(SidebarSelection.server)
            }
            Section {
                ForEach(model.config.mounts) { mount in
                    let s = model.status(for: mount)
                    SidebarRow(color: s != nil ? .green : (model.server.isEnabled ? .orange : .gray),
                               title: mount.name, detail: mountDetail(s), listeners: s?.listeners)
                        .tag(SidebarSelection.mount(mount.id))
                }
            } header: {
                HStack {
                    Text("Mounts")
                    Spacer()
                    Button {
                        selection = .mount(model.addMount().id)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Add a mount point")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { VersionFooter() }
    }

    private var serverDetail: String {
        switch model.server.state {
        case .stopped: return "Off"
        case .needsApproval: return "Needs approval"
        case .failed: return "Problem"
        case .running:
            guard model.poller.reachable else { return "Starting…" }
            let n = model.poller.status?.totalListeners ?? 0
            return "Running · port \(model.config.server.port) · \(n) \(n == 1 ? "listener" : "listeners")"
        }
    }

    private func mountDetail(_ s: MountStatus?) -> String {
        if let s { return s.bitrate.map { "On air · \($0) kbps" } ?? "On air" }
        return model.server.isEnabled ? "No encoder" : "Server off"
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

/// "LogiKast 1.0b4 (14)" at the bottom of the sidebar; clicking it opens the About window.
/// The build number is shown because a rebuilt beta keeps the same public version.
struct VersionFooter: View {
    static var text: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "LogiKast \(version) (\(build))"
    }

    var body: some View {
        Button { AboutPanel.show() } label: {
            Text(Self.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("About LogiKast")
    }
}

/// A sidebar entry: status dot, a prominent name, a small gray line of detail, and optionally the listener count.
struct SidebarRow: View {
    var color: Color
    var title: String
    var detail: String
    var listeners: Int?

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let listeners {
                Label("\(listeners)", systemImage: "headphones")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
}

/// The header as a toolbar item. Newer macOS wraps every toolbar item in a rounded background and has no title to push the
/// buttons aside; the header is text, so it drops the background and a flexible space keeps the Start/Stop button at the right.
struct HeaderToolbar: ToolbarContent {
    var selection: SidebarSelection?

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { WindowHeader(selection: selection) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem(placement: .principal) { WindowHeader(selection: selection) }
        }
    }
}

/// Removes the toolbar's sidebar button (macOS 14 and later) and the View menu's Show/Hide Sidebar is removed in AppCommands.
struct NoSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) { content.toolbar(removing: .sidebarToggle) } else { content }
    }
}

/// The top of the window: the app's name, then the selected sidebar item in large type.
struct WindowHeader: View {
    @EnvironmentObject var model: AppModel
    var selection: SidebarSelection?

    private var title: String {
        if case .mount(let id) = selection, let mount = model.config.mounts.first(where: { $0.id == id }) { return mount.name }
        return "Server"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("LogiKast").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 17, weight: .bold)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, 6)
    }
}

/// Window chrome the SwiftUI scene can't express on macOS 13:
/// - The header above replaces the title bar's own text (the window keeps its title for Mission Control and the Window menu).
/// - macOS gives the window's first text field (the Port) keyboard focus, with its text selected, when the window opens.
///   Hand the focus back to nobody, so a field is only edited once the user clicks it.
private struct WindowSetup: NSViewRepresentable {
    final class HostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }
    }

    func makeNSView(context: Context) -> NSView { HostView() }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.titleVisibility = .hidden
        guard !context.coordinator.done else { return }
        context.coordinator.done = true
        // The first responder is assigned after the window appears, so clear it a moment later (twice, to be sure).
        for delay in [0.0, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                view?.window?.titleVisibility = .hidden
                guard let window = view?.window, window.firstResponder is NSText else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var done = false }
}
