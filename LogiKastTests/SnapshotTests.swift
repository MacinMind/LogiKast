import XCTest
import SwiftUI
@testable import LogiKast

/// Renders views offscreen to PNGs for visual review. Only runs when
/// TEST_RUNNER_LOGIKAST_SNAPSHOT_DIR is set (xcodebuild passes it as LOGIKAST_SNAPSHOT_DIR).
@MainActor
final class SnapshotTests: XCTestCase {
    func testRenderWizardSteps() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOGIKAST_SNAPSHOT_DIR"] else {
            throw XCTSkip("snapshot directory not set")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = AppModel()
        // The mount page (this is where raw markdown once showed up in a heading).
        struct MountHost: View {
            @State var mount = Mount()
            var body: some View { MountView(mount: $mount) }
        }

        try snapshot(SetupWizard(initialStep: .welcome, isRerun: true).environmentObject(model),
                     size: NSSize(width: 640, height: 650), to: "wizard-rerun-welcome.png", in: dir)

        struct BackupHost: View {
            @State var mount: Mount = {
                var m = Mount(); m.backupFile = "live-backup.mp3"; m.backupName = "Be Right Back.mp3"; return m
            }()
            var body: some View { MountView(mount: $mount) }
        }

        // Every tab of the mount and server pages, at a realistic window size.
        for tab in MountTab.allCases {
            model.mountTab = tab
            try snapshot(MountHost().environmentObject(model), size: NSSize(width: 700, height: 820), to: "mount-\(tab.rawValue).png", in: dir)
        }
        model.mountTab = .backup
        try snapshot(BackupHost().environmentObject(model), size: NSSize(width: 700, height: 820), to: "mount-backup-withfile.png", in: dir)
        // Relay mounts: the source settings, a relay as the backup, and the mount's relay address.
        struct RelayHost: View {
            @State var mount: Mount = {
                var m = Mount(); m.name = "/relayed"; m.isRelay = true
                m.relay.server = "radio.example.com"; m.relay.mount = "/main"; return m
            }()
            var body: some View { MountView(mount: $mount) }
        }
        struct RelayBackupHost: View {
            @State var mount: Mount = {
                var m = Mount(); m.backupIsRelay = true; m.backupRelay.server = "backup.example.com"; m.backupRelay.mount = "/b"; return m
            }()
            var body: some View { MountView(mount: $mount) }
        }
        struct MasterListHost: View {
            var body: some View {
                Form {
                    Section {
                        Toggle("Relay all mounts from another Icecast server", isOn: .constant(true))
                        RelayedMountList(mounts: ["/live", "/jazz", "/rock", "/news"], onDemand: false)
                    } header: { Text("Relay everything from another server") }
                }.formStyle(.grouped)
            }
        }
        try snapshot(MasterListHost().environmentObject(model), size: NSSize(width: 700, height: 520), to: "master-relay-list.png", in: dir)
        model.mountTab = .connect
        try snapshot(RelayHost().environmentObject(model), size: NSSize(width: 700, height: 820), to: "mount-relay-connect.png", in: dir)
        model.mountTab = .backup
        try snapshot(RelayHost().environmentObject(model), size: NSSize(width: 700, height: 820), to: "mount-relay-backup.png", in: dir)
        try snapshot(RelayBackupHost().environmentObject(model), size: NSSize(width: 700, height: 820), to: "mount-backup-relay.png", in: dir)
        for tab in ServerTab.allCases {
            model.serverTab = tab
            try snapshot(ServerView().environmentObject(model), size: NSSize(width: 700, height: 820), to: "server-\(tab.rawValue).png", in: dir)
        }

        for step in WizardStep.allCases {
            let host = NSHostingView(rootView: SetupWizard(initialStep: step).environmentObject(model))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 650)
            // A real (never shown) window, so AppKit-backed controls such as Form rows draw.
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))   // let .onAppear / state settle
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds),
                  let png = { host.cacheDisplay(in: host.bounds, to: rep); return rep.representation(using: .png, properties: [:]) }() else {
                XCTFail("could not render \(step)"); continue
            }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("wizard-\(step.rawValue)-\(step).png"))
        }
    }

    private func snapshot<V: View>(_ view: V, size: NSSize, to name: String, in dir: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("render \(name)") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// Renders each page tall, at the real detail-pane width, so its natural content height can be
    /// measured (only when LOGIKAST_MEASURE_DIR is set).
    func testRenderPagesForHeightMeasurement() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOGIKAST_MEASURE_DIR"] else { throw XCTSkip("not requested") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = AppModel()
        var m = model.config.mounts[0]
        m.streamName = "Radiologik Trance"
        model.config.mounts[0] = m
        // The on-air header (title + format line) is taller than the "off" one, so measure that.
        let live = MountStatus(path: m.name, listeners: 3, peak: 5, title: "Alexander Popov - Elegia (Original Mix Edit)",
                               streamName: "Radiologik Trance", genre: "Trance", streamURL: "https://www.radiologik.com/trance",
                               streamDescription: "A classy and melodic selection of tracks", contentType: "audio/aacp", bitrate: 64,
                               streamStart: Date().addingTimeInterval(-600))
        model.poller.injectForTesting(status: ServerStatus(mounts: [live]))
        struct Host: View {
            @EnvironmentObject var model: AppModel
            @State var mount: Mount
            var body: some View { MountView(mount: $mount) }
        }
        let width: CGFloat = 590   // 865 minimum window width minus the 275 fixed sidebar
        for tab in MountTab.allCases {
            model.mountTab = tab
            try snapshot(Host(mount: m).environmentObject(model), size: NSSize(width: width, height: 1700), to: "m-\(tab.rawValue).png", in: dir)
        }
        for tab in ServerTab.allCases {
            model.serverTab = tab
            try snapshot(ServerView().environmentObject(model), size: NSSize(width: width, height: 1700), to: "s-\(tab.rawValue).png", in: dir)
        }
        // states that make a page taller
        var pub = m; pub.isPublic = true
        model.mountTab = .streamInfo
        try snapshot(Host(mount: pub).environmentObject(model), size: NSSize(width: width, height: 1700), to: "m-streamInfo-public.png", in: dir)
        var bk = m; bk.backupFile = "live-backup.mp3"; bk.backupName = "Be Right Back.mp3"
        model.mountTab = .backup
        try snapshot(Host(mount: bk).environmentObject(model), size: NSSize(width: width, height: 1700), to: "m-backup-file.png", in: dir)
    }
}
