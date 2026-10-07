import XCTest
@testable import LogiKast

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

    func testRelayMountsSayRelayNotEncoder() {
        var tr = AlertTracker()
        func go(_ t: TimeInterval, _ st: ServerStatus) -> [AlertEvent] {
            tr.update(now: at(t), enabled: true, status: st, serverLimit: 0, mountLimits: [:], relayMounts: ["/r"])
        }
        _ = go(0, status([("/live", 0)]))
        XCTAssertEqual(go(2, status([("/live", 0), ("/r", 0)])), [.relayConnected(mount: "/r")])
        _ = go(3, status([("/live", 0)]))
        XCTAssertEqual(go(8, status([("/live", 0)])), [.relayDropped(mount: "/r")])
        XCTAssertEqual(AlertEvent.relayDropped(mount: "/r").title, "Relay dropped off — /r")
        XCTAssertTrue(AlertEvent.relayDropped(mount: "/r").isUrgent)
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
        XCTAssertEqual(try doc.nodes(forXPath: "//mount/fallback-mount").first?.stringValue, "/_backup/live")
        // the internal mount the feeder streams to is hidden, unlisted and has a small burst
        let internalMount = try XCTUnwrap(doc.nodes(forXPath: "//mount[mount-name='/_backup/live']").first)
        XCTAssertEqual(try internalMount.nodes(forXPath: "hidden").first?.stringValue, "1")
        XCTAssertEqual(try internalMount.nodes(forXPath: "public").first?.stringValue, "0")
        XCTAssertEqual(try internalMount.nodes(forXPath: "burst-size").first?.stringValue, "8192")
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
        guard let dir = ProcessInfo.processInfo.environment["LOGIKAST_BACKUP_SAMPLE_DIR"] else { throw XCTSkip("not requested") }
        var c = AppConfig.makeDefault()
        c.server.port = 18095
        c.server.bindAddress = "127.0.0.1"
        c.mounts[0].name = "/live"
        c.mounts[0].backupFile = "live-backup.mp3"
        let share = ProcessInfo.processInfo.environment["LOGIKAST_SHARE"] ?? "/tmp"
        let web = ProcessInfo.processInfo.environment["LOGIKAST_WEB"] ?? share + "/web"
        let p = IcecastPaths(logDir: dir + "/log", webRoot: web, adminRoot: share + "/admin", baseDir: dir)
        try ConfigWriter.xml(for: c, paths: p).write(toFile: dir + "/icecast.xml", atomically: true, encoding: .utf8)
        try c.server.sourcePassword.write(toFile: dir + "/pw", atomically: true, encoding: .utf8)
        let feeds = BackupFeeds.make(for: c, backupDir: URL(fileURLWithPath: dir), fileExists: { _ in true })
        try BackupFeeds.write(feeds, to: URL(fileURLWithPath: dir + "/backup-feeds.json"))
    }
}


final class BackupFeedsTests: XCTestCase {
    private func config() -> AppConfig {
        var c = AppConfig.makeDefault()
        c.server.port = 8123
        c.server.sourcePassword = "secret"
        c.mounts = [Mount(), Mount()]
        c.mounts[0].name = "/live"; c.mounts[0].backupFile = "live-backup.mp3"
        c.mounts[1].name = "/Jazz Radio"; c.mounts[1].backupFile = "x.aac"
        return c
    }

    func testFeedsFileFromConfig() {
        let dir = URL(fileURLWithPath: "/tmp/b")
        let f = BackupFeeds.make(for: config(), backupDir: dir, fileExists: { _ in true })
        XCTAssertEqual(f.host, "127.0.0.1")
        XCTAssertEqual(f.port, 8123)
        XCTAssertEqual(f.password, "secret")
        XCTAssertEqual(f.feeds.map(\.mount), ["/_backup/live", "/_backup/jazz-radio"])
        XCTAssertEqual(f.feeds[0].file, "/tmp/b/live-backup.mp3")
        XCTAssertEqual(f.feeds.map(\.contentType), ["audio/mpeg", "audio/aac"])
    }

    func testMissingFilesAndNoBackupAreSkippedAndBindAddressIsUsed() {
        var c = config()
        c.mounts[1].backupFile = ""
        c.server.bindAddress = "192.168.1.5"
        let f = BackupFeeds.make(for: c, fileExists: { $0 == "live-backup.mp3" })
        XCTAssertEqual(f.feeds.count, 1)
        XCTAssertEqual(f.host, "192.168.1.5")
        XCTAssertTrue(BackupFeeds.make(for: c, fileExists: { _ in false }).feeds.isEmpty)
    }

    func testWritingIsOwnerOnlyAndSkipsIdenticalContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feeds-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let f = BackupFeeds.make(for: config(), fileExists: { _ in true })
        try BackupFeeds.write(f, to: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)
        try BackupFeeds.write(f, to: url)                                  // unchanged: the feeder must not reconnect
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, first)
        XCTAssertEqual(try JSONDecoder().decode(BackupFeedsFile.self, from: Data(contentsOf: url)), f)
    }

    func testBackupState() {
        var m = Mount(); m.name = "/live"
        let now = Date()
        func st(_ feed: String, _ state: String, age: TimeInterval = 0, detail: String = "") -> BackupFeederStatus {
            .init(updated: now.timeIntervalSince1970 - age, pid: 1, feeds: [.init(mount: feed, state: state, detail: detail)])
        }
        XCTAssertEqual(BackupState.of(mount: m, serverOn: true, status: nil, now: now), .notSet)
        m.backupFile = "live-backup.mp3"
        XCTAssertEqual(BackupState.of(mount: m, serverOn: false, status: nil, now: now), .serverOff)
        XCTAssertEqual(BackupState.of(mount: m, serverOn: true, status: nil, now: now), .notRunning)
        XCTAssertEqual(BackupState.of(mount: m, serverOn: true, status: st("/_backup/live", "streaming", age: 30), now: now), .notRunning, "stale heartbeat")
        XCTAssertEqual(BackupState.of(mount: m, serverOn: true, status: st("/_backup/other", "streaming"), now: now), .notApplied)
        XCTAssertEqual(BackupState.of(mount: m, serverOn: true, status: st("/_backup/live", "connecting"), now: now), .starting)
        XCTAssertEqual(BackupState.of(mount: m, serverOn: true, status: st("/_backup/live", "streaming"), now: now), .ready)
        XCTAssertEqual(BackupState.of(mount: m, serverOn: true, status: st("/_backup/live", "error", detail: "Can't reach the server."), now: now), .problem("Can't reach the server."))
    }

    func testInternalMountsAreHiddenFromTheMountListButCounted() throws {
        let json = #"{"icestats":{"source":[{"listeners":2,"listenurl":"http://h:8000/live","server_type":"audio/mpeg"},{"listeners":3,"listenurl":"http://h:8000/_backup/live","server_type":"audio/mpeg"}]}}"#
        let s = try XCTUnwrap(StatusParser.parse(Data(json.utf8)))
        XCTAssertEqual(s.mounts.map(\.path), ["/live"])
        XCTAssertEqual(s.backupMounts.map(\.path), ["/_backup/live"])
        XCTAssertEqual(s.totalListeners, 5, "listeners hearing the backup are still listeners")
        XCTAssertEqual(s.backupListeners(forMount: "/live"), 3)
        XCTAssertEqual(s.backupListeners(forMount: "/other"), 0)
        // The alert tracker only sees real mounts, so the backup connecting is never "an encoder connecting".
        XCTAssertFalse(s.mounts.contains { BackupAudio.isInternalMount($0.path) })
    }

    func testLeftoverFallbackPlaceholderIsNotAnOnAirMount() throws {
        // Real Icecast output after the encoder dropped: the mount lingers with only a listener count.
        let json = #"{"icestats":{"source":{"listeners":0,"listenurl":"http://h:8000/live"}}}"#
        let s = try XCTUnwrap(StatusParser.parse(Data(json.utf8)))
        XCTAssertTrue(s.mounts.isEmpty, "no encoder, so the mount is not on the air")
        // ...while a connected source carries stream details.
        let live = #"{"icestats":{"source":{"listeners":1,"listenurl":"http://h:8000/live","server_type":"audio/mpeg","stream_start_iso8601":"2026-10-02T00:09:46-0500"}}}"#
        XCTAssertEqual(try XCTUnwrap(StatusParser.parse(Data(live.utf8))).mounts.map(\.path), ["/live"])
    }

    func testAdminStatsListHiddenBackupMounts() {
        let xml = """
        <?xml version="1.0"?><icestats><clients>2</clients><listeners>1</listeners>
        <source mount="/_backup/live"><listeners>1</listeners><server_name>LogiKast backup for /live</server_name></source>
        <source mount="/live"><listeners>0</listeners></source>
        <source mount="/_backup/jazz"><listeners>4</listeners></source></icestats>
        """
        let m = AdminStats.backupMounts(from: Data(xml.utf8))
        XCTAssertEqual(m.map(\.path), ["/_backup/jazz", "/_backup/live"])
        XCTAssertEqual(m.map(\.listeners), [4, 1])
        XCTAssertTrue(AdminStats.backupMounts(from: Data("nope".utf8)).isEmpty)
    }

    func testOldFileLocationIsMigrated() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.legacyBackupDir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: AppPaths.legacyBackupDir.appendingPathComponent("live-backup.mp3"))
        AppPaths.migrateBackupFiles()
        XCTAssertTrue(BackupAudio.exists("live-backup.mp3"))
        XCTAssertFalse(fm.fileExists(atPath: AppPaths.legacyBackupDir.path))
        BackupAudio.remove("live-backup.mp3")
    }
}

@MainActor
final class ProblemHintTests: XCTestCase {
    private func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd  HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        return "[\(f.string(from: d))]"
    }

    func testIgnoresConfigChecksAndOldErrors() {
        let start = Date()
        let lines = [
            "\(stamp(start.addingTimeInterval(-3600))) EROR source/old An old failure",
            "\(stamp(start)) EROR CONFIG/config_parse_file Client limit (10) is too small for given source limit (10)",
        ]
        XCTAssertNil(IcecastService.problemHint(in: lines, since: start))
    }

    func testReturnsTheNewestErrorFromThisStart() {
        let start = Date()
        let lines = [
            "\(stamp(start)) EROR CONFIG/config_parse_file Client limit (10) is too small for given source limit (10)",
            "\(stamp(start.addingTimeInterval(1))) EROR connection/sock_listen Could not create listener socket on port 8000",
            "\(stamp(start.addingTimeInterval(2))) INFO something unrelated",
        ]
        XCTAssertEqual(IcecastService.problemHint(in: lines, since: start)?.contains("Could not create listener socket"), true)
    }
}

@MainActor
final class PortOwnerTests: XCTestCase {
    func testFindsTheProgramListeningOnAPort() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var out = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: out.sin_port))

        let owners = PortCheck.owners(port: port)
        XCTAssertEqual(owners.first?.pid, getpid())
        XCTAssertEqual(owners.first?.isOurs, false)          // not started by our supervisor
        XCTAssertTrue(PortCheck.owners(port: 1).isEmpty)
    }

    func testOnlyTheSupervisedServerCountsAsOurs() {
        XCTAssertTrue(PortOwner(pid: 1, name: "icecast", parentName: "/Apps/LogiKast.app/Contents/Helpers/logikast-launch").isOurs)
        XCTAssertFalse(PortOwner(pid: 1, name: "icecast", parentName: "/sbin/launchd").isOurs)
    }

    func testMessageNamesTheOtherServer() {
        let text = IcecastService.portConflictText(port: 8000, owner: PortOwner(pid: 4242, name: "icecast", parentName: "/sbin/launchd"))
        XCTAssertTrue(text.contains("Port 8000"))
        XCTAssertTrue(text.contains("4242"))
        XCTAssertTrue(text.contains("another Icecast"))
    }
}
