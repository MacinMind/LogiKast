#if DEBUG
import SwiftUI

// Xcode previews (Editor ▸ Canvas, or ⌥⌘↩). Each #Preview below is one screen with sample data, so you can
// see and adjust the layout without running the app. Previews run in an isolated temporary folder (see
// RunContext), so they never touch your settings, your running server or the network.

/// Sample stations and server states for the previews.
@MainActor
enum PreviewData {
    /// A configured station with two mounts. `onAir` fakes a connected encoder on /live.
    static func model(onAir: Bool = true, mountTab: MountTab = .connect, serverTab: ServerTab = .setup) -> AppModel {
        let model = AppModel()
        model.config.setupCompleted = true
        model.config.server.hostname = "radio.example.com"
        var jazz = Mount()
        jazz.name = "/jazz"
        jazz.streamName = "Late Night Jazz"
        model.config.mounts = [liveMount, jazz]
        model.showSetup = false
        model.showLegacyPrompt = false
        model.mountTab = mountTab
        model.serverTab = serverTab
        if onAir {
            let live = MountStatus(path: "/live", listeners: 3, peak: 5, title: "Alexander Popov - Elegia (Original Mix Edit)",
                                   streamName: "Radiologik Trance", genre: "Trance", streamURL: "https://www.radiologik.com/trance",
                                   streamDescription: "A classy and melodic selection of tracks", contentType: "audio/aacp",
                                   bitrate: 64, sampleRate: 44100, channels: 2, streamStart: Date().addingTimeInterval(-1800))
            model.poller.injectForTesting(status: ServerStatus(mounts: [live]))
        }
        return model
    }

    static var liveMount: Mount {
        var m = Mount()
        m.streamName = "Radiologik Trance"
        m.streamDescription = "A classy and melodic selection of tracks"
        m.genre = "Trance"
        m.streamURL = "https://www.radiologik.com/trance"
        return m
    }

    static var backupFileMount: Mount {
        var m = liveMount
        m.backupFile = "live-backup-he.aac"
        m.backupName = "Be Right Back.wav"
        return m
    }

    static var backupServerMount: Mount {
        var m = liveMount
        m.backupIsRelay = true
        m.backupRelay.server = "backup.example.com"
        m.backupRelay.mount = "/standby"
        return m
    }

    static var relayMount: Mount {
        var m = Mount()
        m.name = "/relayed"
        m.isRelay = true
        m.relay.server = "radio.example.com"
        m.relay.mount = "/main"
        return m
    }
}

/// Shows one mount page at the width it has in the real window (865 minimum window width minus the 275 sidebar).
struct MountPagePreview: View {
    @ObservedObject var model: AppModel
    @State var mount: Mount
    var body: some View {
        MountView(mount: $mount)
            .environmentObject(model)
            .frame(width: 590, height: 720)
    }
}

struct ServerPagePreview: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ServerView()
            .environmentObject(model)
            .frame(width: 590, height: 720)
    }
}

// MARK: Mount pages

#Preview("Mount: Connect") { MountPagePreview(model: PreviewData.model(mountTab: .connect), mount: PreviewData.liveMount) }
#Preview("Mount: Stream Info") { MountPagePreview(model: PreviewData.model(mountTab: .streamInfo), mount: PreviewData.liveMount) }
#Preview("Mount: Share") { MountPagePreview(model: PreviewData.model(mountTab: .share), mount: PreviewData.liveMount) }
#Preview("Mount: Listeners") { MountPagePreview(model: PreviewData.model(mountTab: .listeners), mount: PreviewData.liveMount) }
#Preview("Mount: Backup, none") { MountPagePreview(model: PreviewData.model(mountTab: .backup), mount: PreviewData.liveMount) }
#Preview("Mount: Backup, audio file") { MountPagePreview(model: PreviewData.model(mountTab: .backup), mount: PreviewData.backupFileMount) }
#Preview("Mount: Backup, other server") { MountPagePreview(model: PreviewData.model(mountTab: .backup), mount: PreviewData.backupServerMount) }
#Preview("Mount: Advanced") { MountPagePreview(model: PreviewData.model(mountTab: .advanced), mount: PreviewData.liveMount) }
#Preview("Mount: Waiting for encoder") { MountPagePreview(model: PreviewData.model(onAir: false, mountTab: .connect), mount: PreviewData.liveMount) }
#Preview("Mount: From another server") { MountPagePreview(model: PreviewData.model(onAir: false, mountTab: .connect), mount: PreviewData.relayMount) }

// MARK: Server pages

#Preview("Server: Setup") { ServerPagePreview(model: PreviewData.model(serverTab: .setup)) }
#Preview("Server: Limits") { ServerPagePreview(model: PreviewData.model(serverTab: .limits)) }
#Preview("Server: Relay") { ServerPagePreview(model: PreviewData.model(serverTab: .relay)) }
#Preview("Server: Alerts") { ServerPagePreview(model: PreviewData.model(serverTab: .alerts)) }
#Preview("Server: App & Log") { ServerPagePreview(model: PreviewData.model(serverTab: .app)) }
#Preview("Server: Updates") { ServerPagePreview(model: PreviewData.model(serverTab: .updates)) }

// MARK: Whole window

#Preview("Window: Server") {
    ContentView(initialSelection: .server)
        .environmentObject(PreviewData.model(serverTab: .setup))
        .frame(width: 960, height: 700)
}

#Preview("Window: Mount") {
    let model = PreviewData.model(mountTab: .backup)
    return ContentView(initialSelection: .mount(model.config.mounts[0].id))
        .environmentObject(model)
        .frame(width: 960, height: 700)
}

// MARK: Setup assistant

#Preview("Setup: Welcome") { SetupWizard(initialStep: .welcome).environmentObject(PreviewData.model()).frame(width: 640, height: 650) }
#Preview("Setup: Your station") { SetupWizard(initialStep: .station).environmentObject(PreviewData.model()).frame(width: 640, height: 650) }
#Preview("Setup: Network") { SetupWizard(initialStep: .network).environmentObject(PreviewData.model()).frame(width: 640, height: 650) }
#Preview("Setup: Listeners") { SetupWizard(initialStep: .listeners).environmentObject(PreviewData.model()).frame(width: 640, height: 650) }
#Preview("Setup: Encoder") { SetupWizard(initialStep: .encoder).environmentObject(PreviewData.model()).frame(width: 640, height: 650) }

// MARK: Pieces

#Preview("Relay: mounts from another server") {
    Form {
        Section {
            RelayedMountList(mounts: ["/live", "/jazz", "/rock", "/news"], onDemand: false)
        } header: { Text("Relay everything from another server") }
    }
    .formStyle(.grouped)
    .frame(width: 590, height: 420)
}
#endif
