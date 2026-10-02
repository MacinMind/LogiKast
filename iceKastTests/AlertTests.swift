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

final class BackupAudioTests: XCTestCase {
    private let mp3Frame: [UInt8] = [0xFF, 0xFB, 0x90, 0x00]          // MPEG-1 Layer III frame header
    private let aacADTS: [UInt8] = [0xFF, 0xF1, 0x50, 0x80]           // ADTS, MPEG-4 AAC-LC
    private let m4a: [UInt8] = [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20]

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("backup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func file(_ bytes: [UInt8], named name: String, in dir: URL, padTo size: Int = 4096) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes + [UInt8](repeating: 0, count: max(0, size - bytes.count))).write(to: url)
        return url
    }

    func testSniffing() {
        XCTAssertEqual(BackupAudio.sniff(Data(mp3Frame)), .mp3)
        XCTAssertEqual(BackupAudio.sniff(Data([0x49, 0x44, 0x33, 0x04, 0x00])), .mp3, "ID3 tag first")
        XCTAssertEqual(BackupAudio.sniff(Data(aacADTS)), .aac)
        XCTAssertNil(BackupAudio.sniff(Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00])), "WAV is not streamable")
        XCTAssertNil(BackupAudio.sniff(Data([0xFF])))
        XCTAssertTrue(BackupAudio.isMP4(Data(m4a)))
        XCTAssertFalse(BackupAudio.isMP4(Data(mp3Frame)))
    }

    func testSlugAndStoredName() {
        XCTAssertEqual(BackupAudio.slug("/live"), "live")
        XCTAssertEqual(BackupAudio.slug("/My Radio_2"), "my-radio-2")
        XCTAssertEqual(BackupAudio.slug("/"), "mount")
        XCTAssertEqual(BackupAudio.storedName(forMount: "/live", kind: .aac), "live-backup.aac")
    }

    func testInstallCopiesAndReplaces() throws {
        let dir = try tempDir(), dest = dir.appendingPathComponent("web-backup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try file(mp3Frame, named: "My Loop.mp3", in: dir)
        let first = try BackupAudio.install(from: a, mountName: "/live", into: dest)
        XCTAssertEqual(first.storedName, "live-backup.mp3")
        XCTAssertEqual(first.displayName, "My Loop.mp3")
        XCTAssertEqual(first.kind, .mp3)
        XCTAssertTrue(BackupAudio.exists(first.storedName, in: dest))

        // Replacing with an AAC file removes the old MP3 for that mount.
        let b = try file(aacADTS, named: "loop.aac", in: dir)
        let second = try BackupAudio.install(from: b, mountName: "/live", into: dest)
        XCTAssertEqual(second.storedName, "live-backup.aac")
        XCTAssertFalse(BackupAudio.exists("live-backup.mp3", in: dest))
        XCTAssertTrue(BackupAudio.exists("live-backup.aac", in: dest))

        BackupAudio.remove("live-backup.aac", from: dest)
        XCTAssertFalse(BackupAudio.exists("live-backup.aac", in: dest))
        BackupAudio.remove("../escape", from: dest)       // never leaves the backup folder
    }

    func testRejections() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("b")
        XCTAssertThrowsError(try BackupAudio.install(from: try file(m4a, named: "x.m4a", in: dir), mountName: "/a", into: dest)) {
            XCTAssertEqual($0 as? BackupAudio.BackupError, .mp4Container)
        }
        XCTAssertThrowsError(try BackupAudio.install(from: try file([0x52, 0x49, 0x46, 0x46], named: "x.wav", in: dir), mountName: "/a", into: dest)) {
            XCTAssertEqual($0 as? BackupAudio.BackupError, .unsupported)
        }
        XCTAssertThrowsError(try BackupAudio.install(from: dir.appendingPathComponent("missing.mp3"), mountName: "/a", into: dest)) {
            XCTAssertEqual($0 as? BackupAudio.BackupError, .unreadable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a-backup.mp3").path))
    }

    func testWriterUsesTheBackupFileAndAlwaysReturnsListenersToLive() throws {
        var c = AppConfig.makeDefault()
        c.mounts[0].name = "/live"
        c.mounts[0].fallbackMount = "/other"
        c.mounts[0].fallbackOverride = false
        c.mounts[0].backupFile = "live-backup.mp3"
        let xml = ConfigWriter.xml(for: c, paths: IcecastPaths(logDir: "/l", webRoot: "/w", adminRoot: "/a", baseDir: "/b"))
        let doc = try XMLDocument(xmlString: xml)
        XCTAssertEqual(try doc.nodes(forXPath: "//mount/fallback-mount").first?.stringValue, "/backup/live-backup.mp3")
        XCTAssertEqual(try doc.nodes(forXPath: "//mount/fallback-override").first?.stringValue, "1")

        c.mounts[0].backupFile = ""
        let plain = try XMLDocument(xmlString: ConfigWriter.xml(for: c, paths: IcecastPaths(logDir: "/l", webRoot: "/w", adminRoot: "/a", baseDir: "/b")))
        XCTAssertEqual(try plain.nodes(forXPath: "//mount/fallback-mount").first?.stringValue, "/other")
        XCTAssertEqual(try plain.nodes(forXPath: "//mount/fallback-override").first?.stringValue, "0")
    }

    func testMissingBackupFileIsAWarning() {
        var c = AppConfig.makeDefault()
        c.mounts[0].backupFile = "live-backup.mp3"
        let missing = ConfigValidator.issues(for: c, backupExists: { _ in false })
        XCTAssertTrue(missing.contains { $0.severity == .warning && $0.message.contains("backup audio file") })
        XCTAssertFalse(ConfigValidator.hasErrors(c))
        XCTAssertFalse(ConfigValidator.issues(for: c, backupExists: { _ in true }).contains { $0.message.contains("backup audio file") })
    }

    func testOldConfigHasNoBackup() throws {
        let m = try JSONDecoder().decode(Mount.self, from: Data(#"{"name":"/x"}"#.utf8))
        XCTAssertEqual(m.backupFile, "")
        XCTAssertEqual(m.backupName, "")
    }

    /// Writes a sample config (real writer output) for a manual end-to-end check with Icecast.
    func testWriteBackupSampleConfig() throws {
        guard let dir = ProcessInfo.processInfo.environment["ICEKAST_BACKUP_SAMPLE_DIR"] else { throw XCTSkip("not requested") }
        var c = AppConfig.makeDefault()
        c.server.port = 18095
        c.server.bindAddress = "127.0.0.1"
        c.mounts[0].name = "/live"
        c.mounts[0].backupFile = "live-backup.mp3"
        let share = ProcessInfo.processInfo.environment["ICEKAST_SHARE"] ?? "/tmp"
        let web = ProcessInfo.processInfo.environment["ICEKAST_WEB"] ?? share + "/web"
        let p = IcecastPaths(logDir: dir + "/log", webRoot: web, adminRoot: share + "/admin", baseDir: dir)
        try ConfigWriter.xml(for: c, paths: p).write(toFile: dir + "/icecast.xml", atomically: true, encoding: .utf8)
        try c.server.sourcePassword.write(toFile: dir + "/pw", atomically: true, encoding: .utf8)
    }
}
