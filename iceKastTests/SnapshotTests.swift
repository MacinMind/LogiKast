import XCTest
import SwiftUI
@testable import iceKast

/// Renders views offscreen to PNGs for visual review. Only runs when
/// TEST_RUNNER_ICEKAST_SNAPSHOT_DIR is set (xcodebuild passes it as ICEKAST_SNAPSHOT_DIR).
@MainActor
final class SnapshotTests: XCTestCase {
    func testRenderWizardSteps() throws {
        guard let dir = ProcessInfo.processInfo.environment["ICEKAST_SNAPSHOT_DIR"] else {
            throw XCTSkip("snapshot directory not set")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = AppModel()
        // The mount page (this is where raw markdown once showed up in a heading).
        struct MountHost: View {
            @State var mount = Mount()
            var body: some View { MountView(mount: $mount, onDelete: {}) }
        }
        try snapshot(MountHost().environmentObject(model), size: NSSize(width: 640, height: 1750), to: "mount.png", in: dir)

        try snapshot(SetupWizard(initialStep: .welcome, isRerun: true).environmentObject(model),
                     size: NSSize(width: 640, height: 650), to: "wizard-rerun-welcome.png", in: dir)

        struct BackupHost: View {
            @State var mount: Mount = {
                var m = Mount(); m.backupFile = "live-backup.mp3"; m.backupName = "Be Right Back.mp3"; return m
            }()
            var body: some View { MountView(mount: $mount, onDelete: {}) }
        }
        try snapshot(BackupHost().environmentObject(model), size: NSSize(width: 640, height: 1900), to: "mount-backup.png", in: dir)
        try snapshot(ServerView().environmentObject(model), size: NSSize(width: 640, height: 1700), to: "server.png", in: dir)

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
}
