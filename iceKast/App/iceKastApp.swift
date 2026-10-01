import SwiftUI
import AppKit

@main
struct iceKastApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("iceKast", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .help) {
                Button("Setup Assistant…") { model.showSetup = true }
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
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
            model.showSetup = true
        }
        Button("Open iceKast…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit iceKast (server keeps running)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch model.server.state {
        case .stopped: return "Server is off"
        case .running: return model.poller.reachable ? "Server is running" : "Server is starting…"
        case .needsApproval: return "Needs approval in Login Items"
        case .failed: return "Server problem — open iceKast"
        }
    }
}
