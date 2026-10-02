import XCTest
@testable import LogiKast

final class ListenerTests: XCTestCase {
    // Real response from Icecast 2.5.0 listclients.
    let xml = """
    <?xml version="1.0"?>
    <icestats><modules/><source mount="/live"><listeners>2</listeners>
    <listener id="2"><id>2</id><ip>127.0.0.1</ip><useragent>TestPlayer/1.0</useragent><connected>75</connected></listener>
    <listener id="5"><id>5</id><ip>10.0.0.8</ip><useragent></useragent><connected>3700</connected></listener>
    </source></icestats>
    """

    func testParsesListeners() {
        let l = ListenerParser.parse(Data(xml.utf8))
        XCTAssertEqual(l.map(\.id), ["2", "5"])
        XCTAssertEqual(l[0].ip, "127.0.0.1")
        XCTAssertEqual(l[0].player, "TestPlayer/1.0")
        XCTAssertEqual(l[1].player, "Unknown player")
        XCTAssertEqual(l[0].connectedText, "1m 15s")
        XCTAssertEqual(l[1].connectedText, "1h 1m")
    }

    func testBackupFlagAndEmpty() {
        XCTAssertTrue(ListenerParser.parse(Data(xml.utf8), onBackup: true).allSatisfy(\.onBackup))
        XCTAssertTrue(ListenerParser.parse(Data("<icestats/>".utf8)).isEmpty)
        XCTAssertTrue(ListenerParser.parse(Data("junk".utf8)).isEmpty)
    }
}

final class ListenerScaleTests: XCTestCase {
    private func xml(count: Int) -> Data {
        let agents = ["VLC/3.0.24 LibVLC/3.0.24", "iTunes/12.13", "TuneIn/28.1", "okhttp/4.12.0", ""]
        var s = "<?xml version=\"1.0\"?><icestats><modules/><source mount=\"/live\"><listeners>\(count)</listeners>"
        for i in 0..<count {
            s += "<listener id=\"\(i)\"><id>\(i)</id><ip>10.\(i / 250).\(i % 250).1</ip><useragent>\(agents[i % agents.count])</useragent><host>x:8000</host><connected>\((i * 7) % 5000)</connected><role>anonymous</role><acl>anonymous</acl><tls>false</tls><protocol>http</protocol><history><mount>/live</mount></history></listener>"
        }
        return Data((s + "</source></icestats>").utf8)
    }

    func testThousandListenersParseQuickly() {
        let data = xml(count: 1000)
        let start = Date()
        let l = ListenerParser.parse(data)
        let took = Date().timeIntervalSince(start)
        XCTAssertEqual(l.count, 1000)
        print("PERF parse 1000 listeners (\(data.count) bytes): \(Int(took * 1000)) ms")
        XCTAssertLessThan(took, 0.5)
    }

    func testTenThousandListenersStillWork() {
        let l = ListenerParser.parse(xml(count: 10_000))
        XCTAssertEqual(l.count, 10_000)
        let start = Date()
        _ = ListenerList.filtered(l, search: "10.3.", sort: .longest)
        _ = ListenerList.summary(l)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testSearchSortAndSummary() {
        let l = ListenerParser.parse(xml(count: 1000))
        XCTAssertEqual(ListenerList.filtered(l, search: "itunes", sort: .newest).count, 200)
        XCTAssertEqual(ListenerList.filtered(l, search: "10.2.5.1", sort: .newest).first?.ip, "10.2.5.1")
        let newest = ListenerList.filtered(l, sort: .newest)
        XCTAssertTrue(zip(newest, newest.dropFirst()).allSatisfy { $0.connectedSeconds <= $1.connectedSeconds })
        let s = ListenerList.summary(l)
        XCTAssertEqual(s.total, 1000)
        XCTAssertEqual(s.uniqueAddresses, 1000)
        XCTAssertEqual(s.topPlayers.count, 3)
        XCTAssertEqual(s.topPlayers.first?.count, 200)
        XCTAssertEqual(ListenerList.family(of: "VLC/3.0.24 LibVLC/3.0.24"), "VLC")
    }

    func testRefreshSlowsDownAsAudienceGrows() {
        XCTAssertEqual(ListenerList.refreshInterval(listenerCount: 5), 3)
        XCTAssertEqual(ListenerList.refreshInterval(listenerCount: 300), 5)
        XCTAssertEqual(ListenerList.refreshInterval(listenerCount: 1000), 10)
    }
}
