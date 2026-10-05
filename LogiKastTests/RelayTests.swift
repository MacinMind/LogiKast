import XCTest
@testable import LogiKast

final class RelayConfigTests: XCTestCase {
    private let paths = IcecastPaths(logDir: "/l", webRoot: "/w", adminRoot: "/a", baseDir: "/b")

    private func relayMount(named name: String = "/relayed") -> Mount {
        var m = Mount()
        m.name = name
        m.isRelay = true
        m.relay.server = "radio.example.com"
        m.relay.port = 8100
        m.relay.mount = "/main"
        return m
    }

    func testRelayMountNestsRelayBlockInItsMount() throws {
        var c = AppConfig.makeDefault()
        var m = relayMount()
        m.relay.username = "u"
        m.relay.password = "p&q"
        m.customPassword = "ignored"
        c.mounts = [m]
        let xml = ConfigWriter.xml(for: c, paths: paths)
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
        let doc = try XMLDocument(xmlString: xml)
        let relay = try XCTUnwrap(doc.nodes(forXPath: "//mount[mount-name='/relayed']/relay").first as? XMLElement)
        func value(_ tag: String) -> String? { relay.elements(forName: tag).first?.stringValue }
        XCTAssertEqual(value("server"), "radio.example.com")
        XCTAssertEqual(value("port"), "8100")
        XCTAssertEqual(value("mount"), "/main")
        XCTAssertEqual(value("username"), "u")
        XCTAssertEqual(value("password"), "p&q")
        XCTAssertEqual(value("on-demand"), "0")
        XCTAssertFalse(xml.contains("ignored"), "a relay mount takes no encoder, so its encoder password isn't written")
        XCTAssertTrue(xml.contains("<master-update-interval>15</master-update-interval>"), "relays are retried quickly")
    }

    func testNoRelayMeansNoRelayElementsAndTheDefaultRetryInterval() {
        let xml = ConfigWriter.xml(for: AppConfig.makeDefault(), paths: paths)
        XCTAssertFalse(xml.contains("<relay>"))
        XCTAssertFalse(xml.contains("master-update-interval"))
        XCTAssertFalse(xml.contains("relay-password"))
    }

    func testRelayWithoutAServerIsNotWritten() {
        var c = AppConfig.makeDefault()
        var m = relayMount()
        m.relay.server = "  "
        c.mounts = [m]
        XCTAssertFalse(ConfigWriter.xml(for: c, paths: paths).contains("<relay>"))
    }

    func testBackupRelayUsesAHiddenInternalMountAndTheMountFallsBackToIt() throws {
        var c = AppConfig.makeDefault()
        var m = Mount()
        m.name = "/live"
        m.fallbackMount = "/ignored"
        m.fallbackOverride = false
        m.backupIsRelay = true
        m.backupRelay.server = "backup.example.com"
        m.backupRelay.port = 8001
        m.backupRelay.mount = "/b"
        m.backupRelay.onDemand = true
        c.mounts = [m]
        let xml = ConfigWriter.xml(for: c, paths: paths)
        let doc = try XMLDocument(xmlString: xml)
        let internal_ = BackupAudio.internalMount(forMount: "/live")
        XCTAssertEqual(try doc.nodes(forXPath: "//mount[mount-name='/live']/fallback-mount").first?.stringValue, internal_)
        XCTAssertEqual(try doc.nodes(forXPath: "//mount[mount-name='/live']/fallback-override").first?.stringValue, "1", "listeners return to the live stream")
        XCTAssertEqual(try doc.nodes(forXPath: "//mount[mount-name='\(internal_)']/hidden").first?.stringValue, "1")
        XCTAssertEqual(try doc.nodes(forXPath: "//mount[mount-name='\(internal_)']/relay/server").first?.stringValue, "backup.example.com")
        XCTAssertEqual(try doc.nodes(forXPath: "//mount[mount-name='\(internal_)']/relay/on-demand").first?.stringValue, "1")
        XCTAssertFalse(xml.contains("/ignored"))
    }

    func testABackupFileTakesPrecedenceOverABackupRelay() throws {
        var c = AppConfig.makeDefault()
        var m = Mount()
        m.backupFile = "live-backup.mp3"
        m.backupIsRelay = true
        m.backupRelay.server = "backup.example.com"
        c.mounts = [m]
        let xml = ConfigWriter.xml(for: c, paths: paths)
        XCTAssertFalse(xml.contains("<relay>"))
        XCTAssertFalse(xml.contains("master-update-interval"))
    }

    func testAMountCanBeBothARelayAndHaveABackup() throws {
        var c = AppConfig.makeDefault()
        var m = relayMount()
        m.fallbackMount = "/encoder-mount"
        c.mounts = [m, { var e = Mount(); e.name = "/encoder-mount"; return e }()]
        let xml = ConfigWriter.xml(for: c, paths: paths)
        let doc = try XMLDocument(xmlString: xml)
        XCTAssertEqual(try doc.nodes(forXPath: "//mount[mount-name='/relayed']/fallback-mount").first?.stringValue, "/encoder-mount")
        XCTAssertNotNil(try doc.nodes(forXPath: "//mount[mount-name='/relayed']/relay").first)
    }

    func testServerWideRelayingNeedsASwitchAndAPassword() {
        var c = AppConfig.makeDefault()
        c.server.relayPassword = "secret-relay"
        XCTAssertFalse(ConfigWriter.xml(for: c, paths: paths).contains("relay-password"), "off by default")
        c.server.allowRelaying = true
        XCTAssertTrue(ConfigWriter.xml(for: c, paths: paths).contains("<relay-password>secret-relay</relay-password>"))
        c.server.relayPassword = ""
        XCTAssertFalse(ConfigWriter.xml(for: c, paths: paths).contains("relay-password"))
    }

    func testOldConfigsDecodeWithRelayOff() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"mounts":[{"name":"/old"}],"server":{"port":9000}}"#.utf8))
        XCTAssertFalse(c.mounts[0].isRelay)
        XCTAssertFalse(c.mounts[0].backupIsRelay)
        XCTAssertEqual(c.mounts[0].relay.port, 8000)
        XCTAssertFalse(c.server.allowRelaying)
    }

    func testRelaySettingsRoundTrip() throws {
        var c = AppConfig.makeDefault()
        c.mounts = [relayMount()]
        c.mounts[0].backupIsRelay = true
        c.mounts[0].backupRelay.server = "b.example.com"
        c.server.allowRelaying = true
        c.server.relayPassword = "rp"
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }
}

/// Writes configs for a real Icecast, to try the relay settings end to end by hand (skipped unless LOGIKAST_RELAY_OUT is set).
final class RelaySampleConfigs: XCTestCase {
    func testWriteSampleServer() throws {
        guard let out = ProcessInfo.processInfo.environment["LOGIKAST_RELAY_OUT"],
              let share = ProcessInfo.processInfo.environment["LOGIKAST_RELAY_SHARE"] else { throw XCTSkip("LOGIKAST_RELAY_OUT not set") }
        var c = AppConfig.makeDefault()
        c.server.port = 19002
        c.server.hostname = "localhost"
        c.server.sourcePassword = "sp"
        c.server.adminPassword = "pw"
        c.server.maxClients = 60
        c.server.maxSources = 20
        c.server.allowRelaying = true
        c.server.relayPassword = "rp"
        var relayed = Mount(); relayed.name = "/r"; relayed.isRelay = true
        relayed.relay.server = "127.0.0.1"; relayed.relay.port = 19001; relayed.relay.mount = "/x"
        relayed.fallbackMount = "/enc"
        var enc = Mount(); enc.name = "/enc"
        var live = Mount(); live.name = "/a"
        live.backupIsRelay = true
        live.backupRelay.server = "127.0.0.1"; live.backupRelay.port = 19001; live.backupRelay.mount = "/x"; live.backupRelay.onDemand = true
        c.mounts = [relayed, enc, live]
        let paths = IcecastPaths(logDir: out + "/logs", webRoot: share + "/web", adminRoot: share + "/admin", baseDir: share)
        try FileManager.default.createDirectory(atPath: out + "/logs", withIntermediateDirectories: true)
        let xml = ConfigWriter.xml(for: c, paths: paths)
        try xml.write(toFile: out + "/slave.xml", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out + "/slave.xml")
    }
}

final class RelayDemandTests: XCTestCase {
    private func status(_ mounts: [(String, Int)], backups: [(String, Int)] = []) -> ServerStatus {
        func ms(_ p: String, _ l: Int) -> MountStatus { MountStatus(path: p, listeners: l, peak: l) }
        return ServerStatus(mounts: mounts.map { ms($0.0, $0.1) }, backupMounts: backups.map { ms($0.0, $0.1) })
    }

    private func config(onDemand: Bool) -> AppConfig {
        var c = AppConfig.makeDefault()
        var r = Mount(); r.name = "/r"; r.isRelay = true; r.relay.server = "x.example.com"; r.relay.onDemand = onDemand
        var b = Mount(); b.name = "/b"; b.backupIsRelay = true; b.backupRelay.server = "y.example.com"; b.backupRelay.onDemand = onDemand
        c.mounts = [r, b]
        return c
    }

    func testIdleConnectedOnDemandRelaysAreDropped() {
        let st = status([("/r", 0), ("/b", 3)], backups: [(BackupAudio.internalMount(forMount: "/b"), 0)])
        XCTAssertEqual(RelayDemand.idleOnDemandMounts(config: config(onDemand: true), status: st),
                       ["/r", BackupAudio.internalMount(forMount: "/b")])
    }

    func testRelaysWithListenersOrNotConnectedAreLeftAlone() {
        XCTAssertEqual(RelayDemand.idleOnDemandMounts(config: config(onDemand: true), status: status([("/r", 2)])), [])
        XCTAssertEqual(RelayDemand.idleOnDemandMounts(config: config(onDemand: true), status: status([])), [], "not connected: nothing to drop")
        XCTAssertEqual(RelayDemand.idleOnDemandMounts(config: config(onDemand: true), status: nil), [])
    }

    func testAlwaysOnRelaysAreNeverDropped() {
        let st = status([("/r", 0)], backups: [(BackupAudio.internalMount(forMount: "/b"), 0)])
        XCTAssertEqual(RelayDemand.idleOnDemandMounts(config: config(onDemand: false), status: st), [])
    }
}

final class RelayValidationTests: XCTestCase {
    private func issues(_ edit: (inout Mount) -> Void) -> [ConfigIssue] {
        var c = AppConfig.makeDefault()
        var m = Mount()
        m.name = "/live"
        m.isRelay = true
        m.relay.server = "radio.example.com"
        m.relay.mount = "/main"
        edit(&m)
        c.mounts = [m]
        return ConfigValidator.issues(for: c)
    }

    func testAValidRelayHasNoProblems() {
        XCTAssertTrue(issues { _ in }.isEmpty)
    }

    func testCatchesMissingServerBadPortAndMount() {
        XCTAssertTrue(issues { $0.relay.server = "" }.contains { $0.severity == .error && $0.message.contains("enter the server") })
        XCTAssertTrue(issues { $0.relay.port = 0 }.contains { $0.severity == .error && $0.message.contains("port") })
        XCTAssertTrue(issues { $0.relay.mount = "main" }.contains { $0.severity == .error && $0.message.contains("start with /") })
        XCTAssertTrue(issues { $0.relay.server = "http://radio.example.com" }.contains { $0.severity == .error })
    }

    func testCatchesRelayingAMountFromItself() {
        let found = issues { $0.relay.server = "localhost"; $0.relay.port = AppConfig.makeDefault().server.port; $0.relay.mount = "/live" }
        XCTAssertTrue(found.contains { $0.severity == .error && $0.message.contains("from itself") })
    }

    func testAnEncoderMountIsNotCheckedForRelaySettings() {
        XCTAssertTrue(issues { $0.isRelay = false; $0.relay.server = "" }.isEmpty)
    }

    func testBackupRelayIsCheckedOnlyWhenChosen() {
        XCTAssertTrue(issues { $0.isRelay = false; $0.backupIsRelay = false }.isEmpty)
        XCTAssertTrue(issues { $0.isRelay = false; $0.backupIsRelay = true }.contains { $0.message.contains("backup stream") })
    }

    func testServerWideRelayingNeedsAPassword() {
        var c = AppConfig.makeDefault()
        c.server.allowRelaying = true
        c.server.relayPassword = ""
        XCTAssertTrue(ConfigValidator.issues(for: c).contains { $0.severity == .error && $0.message.contains("Relay password") })
    }

    func testRelaysAndBackupRelaysCountAsSources() {
        var c = AppConfig.makeDefault()
        c.server.maxClients = 7          // allows 3 sources
        var a = Mount(); a.name = "/a"; a.isRelay = true; a.relay.server = "x.example.com"
        var b = Mount(); b.name = "/b"; b.backupIsRelay = true; b.backupRelay.server = "y.example.com"
        var d = Mount(); d.name = "/c"
        c.mounts = [a, b, d]             // three mounts plus one backup relay = four sources
        XCTAssertTrue(ConfigValidator.issues(for: c).contains { $0.message.contains("Raise the listener limit") })
    }
}
