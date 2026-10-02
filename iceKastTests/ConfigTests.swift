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
        let json = #"{"icestats":{"source":[{"listeners":1,"listenurl":"http://h:8000/b","server_type":"audio/mpeg"},{"listeners":2,"listenurl":"http://h:8000/a","server_type":"audio/mpeg"}]}}"#
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

final class EncodersTests: XCTestCase {
    func testOrderAndLinks() {
        XCTAssertEqual(Encoders.all.map(\.name), ["Audio Hijack", "LadioCast", "BUTT", "BUTTM"])
        XCTAssertEqual(Encoders.all.map { $0.url.host }, ["rogueamoeba.com", "apps.apple.com", "danielnoethen.de", "buttm.app"])
        XCTAssertEqual(Encoders.all.filter { !$0.sendsDescription }.map(\.name), ["Audio Hijack"])
    }

    func testMarkdownListKeepsOrderAndLinks() {
        let md = Encoders.linkedList
        XCTAssertTrue(md.hasPrefix("[Audio Hijack](https://rogueamoeba.com/audiohijack/), [LadioCast]("))
        XCTAssertTrue(md.hasSuffix(" and [BUTTM](https://buttm.app)"))
        XCTAssertTrue(Encoders.streamInfoNote.contains("[Audio Hijack]"))
        XCTAssertTrue(Encoders.streamInfoNote.contains("not a description"))
    }
}

final class StreamInfoTextTests: XCTestCase {
    func testNewlinesAreRemoved() {
        XCTAssertEqual(StreamInfoText.clean("Line one\nLine two\r\nThree"), "Line oneLine twoThree")
    }

    func testHardLimit() {
        XCTAssertEqual(StreamInfoText.clean(String(repeating: "a", count: 900)).count, StreamInfoText.hardLimit)
        XCTAssertEqual(StreamInfoText.clean("short"), "short")
    }

    func testLimitsStayBelowIcecastsRequestCutoff() {
        // Icecast refuses source connections whose request exceeds 4096 bytes (~3,900 chars of description).
        XCTAssertLessThan(StreamInfoText.hardLimit, 3900)
        XCTAssertLessThan(StreamInfoText.softLimit, StreamInfoText.hardLimit)
    }

    func testConfigNeverContainsLineBreaksInDescription() throws {
        var c = AppConfig.makeDefault()
        c.mounts[0].streamDescription = "One\nTwo"
        let xml = ConfigWriter.xml(for: c, paths: IcecastPaths(logDir: "/l", webRoot: "/w", adminRoot: "/a", baseDir: "/b"))
        let doc = try XMLDocument(xmlString: xml)
        XCTAssertEqual(try doc.nodes(forXPath: "//mount/stream-description").first?.stringValue, "OneTwo")
    }
}

final class SetupChangesTests: XCTestCase {
    private func base() -> AppConfig {
        var c = AppConfig.makeDefault()
        c.mounts[0].name = "/live"
        c.mounts[0].streamName = "My Station"
        return c
    }

    func testNoChangesWhenUntouched() {
        XCTAssertTrue(SetupLogic.changes(from: base(), to: base()).isEmpty)
    }

    func testRenamingTheMountIsFlaggedAsDisruptive() throws {
        var new = base()
        new.mounts[0].name = "/newstation"
        let changes = SetupLogic.changes(from: base(), to: new)
        let mount = try XCTUnwrap(changes.first { $0.text.hasPrefix("Mount name") })
        XCTAssertTrue(mount.disruptive)
        XCTAssertEqual(mount.text, "Mount name: /live → /newstation")
    }

    func testStreamInfoChangeIsNotDisruptive() throws {
        var new = base()
        new.mounts[0].streamName = "Other"
        new.mounts[0].genre = "Jazz"
        let changes = SetupLogic.changes(from: base(), to: new)
        XCTAssertEqual(changes.count, 2)
        XCTAssertFalse(changes.contains { $0.disruptive })
    }

    func testPortAndAudienceAreDisruptive() {
        var new = base()
        new.server.port = 9000
        new.server.bindAddress = "127.0.0.1"
        let changes = SetupLogic.changes(from: base(), to: new)
        XCTAssertEqual(changes.filter(\.disruptive).count, 2)
    }
}

final class DirectoryListingTests: XCTestCase {
    private let paths = IcecastPaths(logDir: "/l", webRoot: "/w", adminRoot: "/a", baseDir: "/b")

    func testEmailRules() {
        XCTAssertFalse(DirectoryListing.isUsableEmail(""))
        XCTAssertFalse(DirectoryListing.isUsableEmail("icemaster@localhost"))
        XCTAssertFalse(DirectoryListing.isUsableEmail("nobody"))
        XCTAssertFalse(DirectoryListing.isUsableEmail("a@b"))
        XCTAssertFalse(DirectoryListing.isUsableEmail("a b@c.com"))
        XCTAssertTrue(DirectoryListing.isUsableEmail("dj@mystation.com"))
    }

    func testPrivateHosts() {
        for h in ["", "localhost", "192.168.1.5", "10.0.0.2", "172.20.1.1", "127.0.0.1", "mac.local"] {
            XCTAssertTrue(DirectoryListing.isPrivateHost(h), h)
        }
        for h in ["203.0.113.9", "mystation.com", "172.32.0.1", "8.8.8.8"] {
            XCTAssertFalse(DirectoryListing.isPrivateHost(h), h)
        }
    }

    func testDirectoryBlockOnlyWhenListedAndEmailPresent() throws {
        var c = AppConfig.makeDefault()
        c.mounts[0].isPublic = true
        XCTAssertFalse(ConfigWriter.xml(for: c, paths: paths).contains("yp-directory"), "no email: Icecast would disable listing")

        c.server.adminEmail = "dj@mystation.com"
        let xml = ConfigWriter.xml(for: c, paths: paths)
        let doc = try XMLDocument(xmlString: xml)
        XCTAssertEqual(try doc.nodes(forXPath: "//yp-directory/@url").first?.stringValue, DirectoryListing.ypURL)
        XCTAssertFalse(xml.contains("<directory>"), "the deprecated block must not be used")
        XCTAssertEqual(try doc.nodes(forXPath: "//mount/public").first?.stringValue, "1")

        c.mounts[0].isPublic = false
        XCTAssertFalse(ConfigWriter.xml(for: c, paths: paths).contains("yp-directory"))
    }

    func testProblemsAreReportedAsWarningsNotErrors() {
        var c = AppConfig.makeDefault()
        c.mounts[0].isPublic = true
        XCTAssertEqual(DirectoryListing.problems(for: c).count, 2)           // no email + localhost
        c.server.bindAddress = "127.0.0.1"
        XCTAssertEqual(DirectoryListing.problems(for: c).count, 3, "loopback-only can't be reached by anyone")
        c.server.bindAddress = ""
        XCTAssertFalse(ConfigValidator.hasErrors(c))
        XCTAssertTrue(ConfigValidator.issues(for: c).contains { $0.severity == .warning && $0.message.contains("contact email") })
        c.server.adminEmail = "dj@mystation.com"
        c.server.hostname = "mystation.com"
        XCTAssertTrue(DirectoryListing.problems(for: c).isEmpty)
    }

    /// Writes a sample config for the manual mock-directory check (only when asked to).
    func testWriteSampleConfigForMockDirectory() throws {
        guard let dir = ProcessInfo.processInfo.environment["ICEKAST_SAMPLE_XML_DIR"] else { throw XCTSkip("not requested") }
        var c = AppConfig.makeDefault()
        c.server.port = 18070
        c.server.bindAddress = "127.0.0.1"
        c.server.hostname = "radio.example.com"
        c.server.adminEmail = "dj@example.com"
        c.mounts[0].name = "/live"
        c.mounts[0].isPublic = true
        c.mounts[0].streamName = "Example Radio"
        c.mounts[0].genre = "Trance"
        let share = ProcessInfo.processInfo.environment["ICEKAST_SHARE"] ?? "/tmp"
        let p = IcecastPaths(logDir: dir + "/log", webRoot: share + "/web", adminRoot: share + "/admin", baseDir: dir)
        try ConfigWriter.xml(for: c, paths: p).write(toFile: dir + "/icecast.xml", atomically: true, encoding: .utf8)
        try c.server.sourcePassword.write(toFile: dir + "/pw", atomically: true, encoding: .utf8)
    }
}

import CoreImage

final class ShareLinksTests: XCTestCase {
    func testLinks() {
        let s = ShareLinks(host: "radio.example.com", port: 8000, mount: "/live", title: "My Station")
        XCTAssertEqual(s.listenURL, "http://radio.example.com:8000/live")
        XCTAssertEqual(s.playlistURL, "http://radio.example.com:8000/live.m3u")
    }

    func testBlankHostFallsBackAndIPv6IsBracketed() {
        XCTAssertEqual(ShareLinks(host: " ", port: 8000, mount: "/a", title: "").listenURL, "http://localhost:8000/a")
        XCTAssertEqual(ShareLinks(host: "2001:db8::1", port: 8000, mount: "/a", title: "").listenURL, "http://[2001:db8::1]:8000/a")
    }

    func testPlayerHTMLEscapesTheTitle() {
        let html = ShareLinks(host: "h.com", port: 80, mount: "/m", title: "Rock & \"Roll\" <live>").playerHTML
        XCTAssertTrue(html.contains("aria-label=\"Rock &amp; &quot;Roll&quot; &lt;live&gt;\""))
        XCTAssertTrue(html.contains("src=\"http://h.com:80/m\""))
        XCTAssertFalse(html.contains("<live>"))
    }

    func testQRCodeDecodesBackToTheLink() throws {
        let url = "http://radio.example.com:8000/live"
        let image = try XCTUnwrap(QRCode.image(for: url, size: 300))
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(found, [url], "the QR code must decode to exactly the listen link")
        XCTAssertNotNil(QRCode.pngData(for: url))
    }
}
