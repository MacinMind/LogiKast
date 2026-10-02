import SwiftUI
import AppKit

@main
struct LogiKastApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("LogiKast", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 730)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About LogiKast") { AboutPanel.show() }
                Button("Check for Updates…") { model.updater.checkForUpdates() }
                    .disabled(!model.updater.canCheck)
            }
            HelpCommands(model: model)
        }

        Window("Version Notes", id: "notes") {
            VersionNotesView(updater: model.updater)
        }
        .defaultSize(width: 520, height: 420)

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
    }
}

/// The Help menu additions.
struct HelpCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button(VersionNotes.menuTitle(includeBetas: model.updater.includeBetas)) { openWindow(id: "notes") }
            Divider()
            Button("Setup Assistant…") { model.requestSetup() }
            Menu("Encoder Apps") { EncoderLinkButtons() }
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.server.isEnabled && model.poller.reachable
                  ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
            if model.server.isEnabled, let s = model.poller.status {
                Text("\(s.totalListeners)").monospacedDigit()
            }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if let status = model.poller.status {
            ForEach(model.config.mounts) { m in
                let l = status.mount(m.name)?.listeners
                Text("\(m.name)  —  \(l.map { "\($0) listening" } ?? "no encoder")")
            }
        }
        Divider()
        if model.server.isEnabled {
            Button("Stop Server") { model.stopServer() }
        } else {
            Button("Start Server") { model.startServer() }.disabled(!model.canStart)
        }
        Button("Setup Assistant…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.requestSetup()
        }
        Menu("Encoder Apps") { EncoderLinkButtons() }
        Button("Open LogiKast…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit LogiKast (server keeps running)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch model.server.state {
        case .stopped: return "Server is off"
        case .running: return model.poller.reachable ? "Server is running" : "Server is starting…"
        case .needsApproval: return "Needs approval in Login Items"
        case .failed: return "Server problem — open LogiKast"
        }
    }
}

/// One menu item per encoder app, opening its website.
struct EncoderLinkButtons: View {
    var body: some View {
        ForEach(Encoders.all) { e in
            Button(e.name) { NSWorkspace.shared.open(e.url) }
        }
    }
}
