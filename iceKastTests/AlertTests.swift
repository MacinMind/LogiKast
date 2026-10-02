import XCTest
@testable import iceKast

final class AlertTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func status(_ mounts: [(String, Int)]) -> ServerStatus {
        ServerStatus(mounts: mounts.map { MountStatus(path: $0.0, listeners: $0.1, peak: $0.1) })
    }
    private func step(_ tr: inout AlertTracker, _ s: TimeInterval, _ st: ServerStatus?, limit: Int = 0, mountLimits: [String: Int] = [:]) -> [AlertEvent] {
        tr.update(now: at(s), enabled: true, status: st, serverLimit: limit, mountLimits: mountLimits)
    }

    func testStreamsAlreadyLiveAtStartAreNotAnnounced() {
        var tr = AlertTracker()
        XCTAssertEqual(step(&tr, 0, status([("/live", 3)])), [])
        XCTAssertEqual(step(&tr, 2, status([("/live", 3)])), [])
    }

    func testEncoderConnectAndDrop() {
        var tr = AlertTracker()
        _ = step(&tr, 0, status([]))
        XCTAssertEqual(step(&tr, 2, status([("/live", 0)])), [.encoderConnected(mount: "/live")])
        XCTAssertEqual(step(&tr, 4, status([])), [], "just gone: wait out the grace period")
        XCTAssertEqual(step(&tr, 6, status([])), [])
        XCTAssertEqual(step(&tr, 8.5, status([])), [.encoderDropped(mount: "/live")])
        XCTAssertEqual(step(&tr, 10, status([])), [], "only once")
    }

    func testQuickReconnectIsQuiet() {
        var tr = AlertTracker()
        _ = step(&tr, 0, status([("/live", 0)]))
        XCTAssertEqual(step(&tr, 2, status([])), [])
        XCTAssertEqual(step(&tr, 3, status([("/live", 0)])), [], "back within the grace period")
        XCTAssertEqual(step(&tr, 20, status([("/live", 0)])), [])
    }

    func testServerOutageAndRecovery() {
        var tr = AlertTracker()
        _ = step(&tr, 0, status([("/live", 2)]))
        XCTAssertEqual(step(&tr, 2, nil), [])
        XCTAssertEqual(step(&tr, 8, nil), [])
        XCTAssertEqual(step(&tr, 12.5, nil), [.serverNotResponding])
        XCTAssertEqual(step(&tr, 14, nil), [], "only once")
        // Comes back: recovered; the stream that was live is reseeded, not announced as dropped.
        XCTAssertEqual(step(&tr, 20, status([("/live", 0)])), [.serverRecovered])
        XCTAssertEqual(step(&tr, 22, status([("/live", 0)])), [])
    }

    func testServerNeverSeenUpDoesNotAlert() {
        var tr = AlertTracker()
        XCTAssertEqual(step(&tr, 0, nil), [])
        XCTAssertEqual(step(&tr, 60, nil), [], "a server that never started is shown in the UI, not as an alert")
    }

    func testBriefOutageUnderGraceIsQuiet() {
        var tr = AlertTracker()
        _ = step(&tr, 0, status([("/live", 1)]))
        XCTAssertEqual(step(&tr, 2, nil), [])
        XCTAssertEqual(step(&tr, 5, status([("/live", 1)])), [])
    }

    func testListenerLimitAlertsOnceWithHysteresis() {
        var tr = AlertTracker()
        _ = step(&tr, 0, status([("/live", 90)]), limit: 100)
        XCTAssertEqual(step(&tr, 2, status([("/live", 100)]), limit: 100),
                       [.listenerLimitReached(mount: nil, listeners: 100, limit: 100)])
        XCTAssertEqual(step(&tr, 4, status([("/live", 99)]), limit: 100), [], "hovering at the cap")
        XCTAssertEqual(step(&tr, 6, status([("/live", 100)]), limit: 100), [])
        XCTAssertEqual(step(&tr, 8, status([("/live", 80)]), limit: 100), [], "dropped well below: re-armed")
        XCTAssertEqual(step(&tr, 10, status([("/live", 100)]), limit: 100).count, 1)
    }

    func testPerMountLimit() {
        var tr = AlertTracker()
        _ = step(&tr, 0, status([("/a", 0), ("/b", 0)]), limit: 1000, mountLimits: ["/a": 5])
        let e = step(&tr, 2, status([("/a", 5), ("/b", 50)]), limit: 1000, mountLimits: ["/a": 5])
        XCTAssertEqual(e, [.listenerLimitReached(mount: "/a", listeners: 5, limit: 5)])
    }

    func testDisabledServerResetsEverything() {
        var tr = AlertTracker()
        _ = step(&tr, 0, status([("/live", 1)]))
        XCTAssertEqual(tr.update(now: at(2), enabled: false, status: nil, serverLimit: 0, mountLimits: [:]), [])
        // After a restart the stream is just "already live" again: no announcement.
        XCTAssertEqual(step(&tr, 30, status([("/live", 1)])), [])
    }

    func testMessagesAndCategories() {
        XCTAssertEqual(AlertEvent.encoderDropped(mount: "/live").title, "Encoder dropped off — /live")
        XCTAssertTrue(AlertEvent.encoderDropped(mount: "/live").isUrgent)
        XCTAssertFalse(AlertEvent.encoderConnected(mount: "/live").isUrgent)
        XCTAssertEqual(AlertEvent.listenerLimitReached(mount: nil, listeners: 100, limit: 100).message,
                       "The server has 100 of 100 listeners. New listeners are being turned away.")
        var n = NotificationSettings()
        XCTAssertTrue(n.allows(.serverNotResponding))
        n.serverProblems = false
        XCTAssertFalse(n.allows(.serverNotResponding))
        XCTAssertTrue(n.allows(.encoderDropped(mount: "/x")))
        n.enabled = false
        XCTAssertFalse(n.allows(.encoderDropped(mount: "/x")))
    }

    func testOldConfigGetsNotificationDefaults() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"server":{"port":9000}}"#.utf8))
        XCTAssertTrue(c.notifications.enabled)
        XCTAssertTrue(c.notifications.encoderEvents)
    }
}
