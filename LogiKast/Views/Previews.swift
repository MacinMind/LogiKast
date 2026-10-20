#if DEBUG
import SwiftUI

// Xcode previews (Editor ▸ Canvas, or ⌥⌘↩). Each view file ends with its own #Preview blocks, so opening a file
// shows its screens in the Canvas. They all use the sample data and helper views in this file. Previews run in an
// isolated temporary folder (see RunContext), so they never touch your settings, your running server or the network.

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
#endif
