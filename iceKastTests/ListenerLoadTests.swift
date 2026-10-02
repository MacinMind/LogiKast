import XCTest
import SwiftUI
@testable import iceKast

/// Load test against a scratch Icecast with ~1000 simulated listeners. Only runs when ICEKAST_LOAD_PORT is set
/// (admin user "admin", password "ap", mount /live); ICEKAST_SNAPSHOT_DIR also saves a picture of the table.
@MainActor
final class ListenerLoadTests: XCTestCase {
    func testThousandListenersEndToEnd() async throws {
        guard let portText = ProcessInfo.processInfo.environment["ICEKAST_LOAD_PORT"], let port = Int(portText) else {
            throw XCTSkip("no load-test server")
        }
        let client = AdminClient(port: port, bindAddress: "127.0.0.1", user: "admin", password: "ap")

        var fetchTimes: [Double] = []
        var listeners: [Listener] = []
        for _ in 0..<5 {
            let t = Date()
            let got = await client.listeners(mount: "/live")
            listeners = try XCTUnwrap(got)
            fetchTimes.append(Date().timeIntervalSince(t) * 1000)
        }
        print("LOAD listeners=\(listeners.count) fetch+parse ms: \(fetchTimes.map { String(Int($0)) }.joined(separator: ", "))")
        XCTAssertGreaterThan(listeners.count, 900)

        var t = Date()
        _ = ListenerList.filtered(listeners, search: "vlc", sort: .address)
        _ = ListenerList.summary(listeners)
        print("LOAD filter+sort+summary ms: \(Int(Date().timeIntervalSince(t) * 1000))")

        // Render the real view with that many listeners and see how long the first draw takes and how a refresh behaves.
        let model = AppModel()
        let counter = Counter()
        let view = ListenersSection(mount: Mount(), source: { counter.n += 1; return listeners }).environmentObject(model)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        t = Date()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        print("LOAD first render (incl. 0.8s settle) ms: \(Int(Date().timeIntervalSince(t) * 1000)), fetches=\(counter.n)")

        t = Date()
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        print("LOAD one full redraw ms: \(Int(Date().timeIntervalSince(t) * 1000))")
        if let dir = ProcessInfo.processInfo.environment["ICEKAST_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("listeners-1000.png"))
        }
    }
}

final class Counter { var n = 0 }
