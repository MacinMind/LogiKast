import XCTest
@testable import iceKast

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

    func testWebAdminURLHasNoCredentials() {
        XCTAssertEqual(WebAdmin.url(port: 8000, bindAddress: "")?.absoluteString, "http://localhost:8000/admin/stats.xsl")
        XCTAssertEqual(WebAdmin.url(port: 8001, bindAddress: "192.168.1.5")?.host, "192.168.1.5")
        XCTAssertNil(WebAdmin.url(port: 8000, bindAddress: "")?.user)
    }
}
