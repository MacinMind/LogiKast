import XCTest
@testable import iceKast

final class ConfigWriterTests: XCTestCase {
    private let paths = IcecastPaths(logDir: "/l", webRoot: "/w", adminRoot: "/a", baseDir: "/b")

    func testWritesMountsAndLimits() throws {
        var c = AppConfig.makeDefault()
        c.server.port = 8123
        c.server.maxClients = 42
        var m = Mount()
        m.name = "/radio"
        m.maxListeners = 7
        m.burstSize = 1234
        m.fallbackMount = "/backup"
        c.mounts = [m]
        let xml = ConfigWriter.xml(for: c, paths: paths)
        XCTAssertTrue(xml.contains("<port>8123</port>"))
        XCTAssertTrue(xml.contains("<clients>42</clients>"))
        XCTAssertTrue(xml.contains("<mount-name>/radio</mount-name>"))
        XCTAssertTrue(xml.contains("<max-listeners>7</max-listeners>"))
        XCTAssertTrue(xml.contains("<burst-size>1234</burst-size>"))
        XCTAssertFalse(xml.contains("<type>"), "format is decided by the encoder, never forced")
        XCTAssertTrue(xml.contains("<fallback-mount>/backup</fallback-mount>"))
        // Must be well-formed XML.
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
    }

    func testEscapesSpecialCharacters() throws {
        var c = AppConfig.makeDefault()
        c.server.sourcePassword = "a&b<c>\"d'"
        c.mounts[0].streamName = "Rock & Roll <live>"
        let xml = ConfigWriter.xml(for: c, paths: paths)
        let doc = try XMLDocument(xmlString: xml)
        let pw = try doc.nodes(forXPath: "//source-password").first?.stringValue
        XCTAssertEqual(pw, "a&b<c>\"d'")
        let name = try doc.nodes(forXPath: "//mount/stream-name").first?.stringValue
        XCTAssertEqual(name, "Rock & Roll <live>")
    }

    func testOmitsOptionalMountFields() {
        var c = AppConfig.makeDefault()
        c.mounts[0].maxListeners = 0
        let xml = ConfigWriter.xml(for: c, paths: paths)
        XCTAssertFalse(xml.contains("<max-listeners>"))
        XCTAssertFalse(xml.contains("<fallback-mount>"))
        XCTAssertFalse(xml.contains("<bind-address>"))
    }

    func testConfigRoundTripAndForwardCompat() throws {
        let c = AppConfig.makeDefault()
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data), c)
        // Old/partial JSON still decodes with defaults.
        let partial = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"server":{"port":9000}}"#.utf8))
        XCTAssertEqual(partial.server.port, 9000)
        XCTAssertEqual(partial.server.maxClients, 100)
    }
}

final class ValidatorTests: XCTestCase {
    func testDefaultIsValid() {
        XCTAssertFalse(ConfigValidator.hasErrors(AppConfig.makeDefault()))
    }

    func testCatchesProblems() {
        var c = AppConfig.makeDefault()
        c.server.port = 80
        c.mounts = [Mount(), Mount()]
        c.mounts[1].name = "no-slash"
        XCTAssertTrue(ConfigValidator.hasErrors(c))
        let msgs = ConfigValidator.issues(for: c).map(\.message).joined(separator: "\n")
        XCTAssertTrue(msgs.contains("1024"))
        XCTAssertTrue(msgs.contains("must start with /"))

        c.server.port = 8000
        c.mounts[1].name = "/live"   // duplicate
        XCTAssertTrue(ConfigValidator.issues(for: c).contains { $0.message.contains("more than once") })

        c.mounts[1].name = "/a b"
        XCTAssertTrue(ConfigValidator.issues(for: c).contains { $0.message.contains("special") })
    }

    func testEmptyPasswordAndSelfFallback() {
        var c = AppConfig.makeDefault()
        c.server.sourcePassword = ""
        c.mounts[0].fallbackMount = c.mounts[0].name
        let msgs = ConfigValidator.issues(for: c).map(\.message).joined(separator: "\n")
        XCTAssertTrue(msgs.contains("Source password"))
        XCTAssertTrue(msgs.contains("itself"))
    }
}

final class StatusParserTests: XCTestCase {
    func testNoSources() throws {
        let json = #"{"icestats":{"server_id":"Icecast 2.5.0","dummy":null}}"#
        let s = try XCTUnwrap(StatusParser.parse(Data(json.utf8)))
        XCTAssertTrue(s.mounts.isEmpty)
        XCTAssertEqual(s.totalListeners, 0)
    }

    func testSingleSourceObject() throws {
        let json = #"{"icestats":{"source":{"listeners":3,"listener_peak":5,"listenurl":"http://h:8000/live.mp3","server_type":"audio/mpeg","title":"Song","stream_start_iso8601":"2026-10-01T13:06:46-0500"}}}"#
        let s = try XCTUnwrap(StatusParser.parse(Data(json.utf8)))
        XCTAssertEqual(s.mounts.count, 1)
        XCTAssertEqual(s.mount("/live.mp3")?.listeners, 3)
        XCTAssertEqual(s.mount("/live.mp3")?.peak, 5)
        XCTAssertEqual(s.mount("/live.mp3")?.title, "Song")
        XCTAssertNotNil(s.mount("/live.mp3")?.streamStart)
    }

    func testMultipleSourcesArray() throws {
        let json = #"{"icestats":{"source":[{"listeners":1,"listenurl":"http://h:8000/b"},{"listeners":2,"listenurl":"http://h:8000/a"}]}}"#
        let s = try XCTUnwrap(StatusParser.parse(Data(json.utf8)))
        XCTAssertEqual(s.mounts.map(\.path), ["/a", "/b"])
        XCTAssertEqual(s.totalListeners, 3)
    }

    func testEncoderStreamInfoIsCaptured() throws {
        let json = #"{"icestats":{"source":{"listeners":1,"listenurl":"http://h:8000/live","server_name":"Radiologik Trance","genre":"Trance","server_url":"https://www.radiologik.com/trance","server_description":"Unspecified description","server_type":"audio/aacp","bitrate":64}}}"#
        let m = try XCTUnwrap(StatusParser.parse(Data(json.utf8))?.mount("/live"))
        XCTAssertEqual(m.streamName, "Radiologik Trance")
        XCTAssertEqual(m.genre, "Trance")
        XCTAssertEqual(m.streamURL, "https://www.radiologik.com/trance")
        XCTAssertNil(m.streamDescription)          // Icecast's placeholder is ignored
        XCTAssertEqual(m.bitrate, 64)
        XCTAssertEqual(StreamFormat(contentType: m.contentType ?? ""), .aacPlus)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(StatusParser.parse(Data("not json".utf8)))
    }
}

@MainActor
final class BadgeTests: XCTestCase {
    private func status(_ pairs: [(String, Int)]) -> ServerStatus {
        ServerStatus(mounts: pairs.map { MountStatus(path: $0.0, listeners: $0.1, peak: $0.1) })
    }

    func testBadgeModes() {
        var c = AppConfig.makeDefault()
        c.mounts = [Mount(), Mount()]
        c.mounts[0].name = "/a"; c.mounts[1].name = "/b"
        let st = status([("/a", 3), ("/b", 4)])

        c.badge = .none
        XCTAssertNil(AppModel.badgeLabel(config: c, status: st))
        c.badge = .total
        XCTAssertEqual(AppModel.badgeLabel(config: c, status: st), "7")
        c.badge = .mount(c.mounts[1].id)
        XCTAssertEqual(AppModel.badgeLabel(config: c, status: st), "4")
    }

    func testBadgeEdgeCases() {
        var c = AppConfig.makeDefault()
        c.badge = .mount(c.mounts[0].id)
        // Server down: no badge. Server up but mount offline: shows 0.
        XCTAssertNil(AppModel.badgeLabel(config: c, status: nil))
        XCTAssertEqual(AppModel.badgeLabel(config: c, status: status([])), "0")
        c.badge = .total
        XCTAssertEqual(AppModel.badgeLabel(config: c, status: status([])), "0")
    }
}

final class PortCheckTests: XCTestCase {
    func testDetectsListeningPort() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = 0
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var out = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: out.sin_port))
        XCTAssertTrue(PortCheck.isInUse(port: port))
        close(fd)
    }

    func testFreePortIsNotInUse() {
        XCTAssertFalse(PortCheck.isInUse(port: 59123))
    }
}

final class ListenSettingsTests: XCTestCase {
    func testReadsPortAndInterfaceFromWrittenConfig() throws {
        var c = AppConfig.makeDefault()
        c.server.port = 9123
        c.server.bindAddress = "192.168.1.5"
        let xml = ConfigWriter.xml(for: c, paths: IcecastPaths(logDir: "/l", webRoot: "/w", adminRoot: "/a", baseDir: "/b"))
        let l = try XCTUnwrap(ListenSettings(xml: xml))
        XCTAssertEqual(l.port, 9123)
        XCTAssertEqual(l.bindAddress, "192.168.1.5")
        XCTAssertEqual(l.key, "9123|192.168.1.5")

        c.server.bindAddress = ""
        let all = try XCTUnwrap(ListenSettings(xml: ConfigWriter.xml(for: c, paths: IcecastPaths(logDir: "/l", webRoot: "/w", adminRoot: "/a", baseDir: "/b"))))
        XCTAssertEqual(all.key, "9123|")
    }

    func testRejectsGarbage() {
        XCTAssertNil(ListenSettings(xml: "not xml"))
    }
}

final class SetupLogicTests: XCTestCase {
    func testBandwidthEstimate() {
        XCTAssertEqual(SetupLogic.uploadMbps(listeners: 100, kbps: 64), 6.4, accuracy: 0.0001)
        XCTAssertEqual(SetupLogic.uploadMbps(listeners: 0, kbps: 128), 0)
        XCTAssertEqual(SetupLogic.describe(mbps: 6.4), "6.4 Mbps")
        XCTAssertEqual(SetupLogic.describe(mbps: 32.1), "33 Mbps")
    }

    func testPortStatus() {
        let busy: Set<Int> = [8000]
        let inUse = { busy.contains($0) }
        XCTAssertEqual(SetupLogic.status(port: 8000, ownPort: nil, isInUse: inUse), .inUse)
        XCTAssertEqual(SetupLogic.status(port: 8000, ownPort: 8000, isInUse: inUse), .available, "our own server's port is fine")
        XCTAssertEqual(SetupLogic.status(port: 8010, ownPort: nil, isInUse: inUse), .available)
        XCTAssertEqual(SetupLogic.status(port: 80, ownPort: nil, isInUse: inUse), .tooLow)
        XCTAssertEqual(SetupLogic.status(port: 0, ownPort: nil, isInUse: inUse), .invalid)
        XCTAssertEqual(SetupLogic.status(port: 70000, ownPort: nil, isInUse: inUse), .invalid)
    }

    func testSuggestPortSkipsBusyOnes() {
        let busy: Set<Int> = [8000, 8010]
        XCTAssertEqual(SetupLogic.suggestPort(preferred: 8000, isInUse: { busy.contains($0) }), 8080)
        XCTAssertEqual(SetupLogic.suggestPort(preferred: 8000, isInUse: { _ in false }), 8000)
        XCTAssertNil(SetupLogic.suggestPort(preferred: 8000, isInUse: { _ in true }))
    }

    func testAudienceMapping() {
        XCTAssertEqual(SetupAudience.thisMac.bindAddress, "127.0.0.1")
        XCTAssertEqual(SetupAudience.anyone.bindAddress, "")
        XCTAssertEqual(SetupAudience(bindAddress: "127.0.0.1"), .thisMac)
        XCTAssertEqual(SetupAudience(bindAddress: ""), .anyone)
        XCTAssertEqual(SetupAudience(bindAddress: "192.168.1.5"), .anyone)
    }

    func testNewInstallNeedsSetupButOldConfigDoesNot() throws {
        XCTAssertFalse(AppConfig.makeDefault().setupCompleted)
        let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"server":{"port":9000}}"#.utf8))
        XCTAssertTrue(old.setupCompleted)
    }
}
