import SwiftUI
import AppKit

@main
struct LogiKastApp: App {
    // Not @StateObject: the app itself must not watch the model. The server status changes every couple of seconds,
    // and every change would rebuild the whole menu bar, even while a menu is open (the Window menu lost most of its items).
    // Views that show model data observe it themselves through the environment.
    @State private var model = AppModel()

    var body: some Scene {
        Window("LogiKast", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 865, minHeight: 730)
        }
        .commands {
            AppCommands(model: model, updater: model.updater)
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

/// The menu bar commands. Watches only the updater (which changes rarely), never the whole model.
struct AppCommands: Commands {
    let model: AppModel
    @ObservedObject var updater: Updater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .sidebar) {}
        CommandGroup(replacing: .appInfo) {
            Button("About LogiKast") { AboutPanel.show() }
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        }
        // Replaces the standard "LogiKast Help" item, which only says that no help book exists.
        CommandGroup(replacing: .help) {
            Button("LogiKast Website") { NSWorkspace.shared.open(HelpLinks.website) }
            Button("Report a Problem…") { NSWorkspace.shared.open(HelpLinks.issues) }
            Button("Icecast Documentation") { NSWorkspace.shared.open(HelpLinks.icecastDocs) }
            Divider()
            Button(VersionNotes.menuTitle(includeBetas: updater.includeBetas)) { openWindow(id: "notes") }
            Divider()
            Button("Setup Assistant…") { model.requestSetup() }
            Menu("Encoder Apps") { EncoderLinkButtons() }
        }
    }
}

/// Where the Help menu sends people.
enum HelpLinks {
    static let website = URL(string: "https://macinmind.com/logikast/info/")!
    static let issues = URL(string: "https://github.com/MacinMind/LogiKast/issues")!
    static let icecastDocs = URL(string: "https://icecast.org/docs/icecast-latest/")!
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
