import XCTest
@testable import LogiKast

final class AdminProxyTests: XCTestCase {
    func testParsesRequestsAndWaitsForTheBody() {
        let head = "POST /admin/x?mount=/live HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nCookie: logikast=t\r\n\r\n"
        XCTAssertNil(AdminProxy.parse(Data("GET / HTTP/1.1\r\nHost: a\r\n".utf8)))                 // headers incomplete
        XCTAssertNil(AdminProxy.parse(Data((head + "abc").utf8)))                                  // body incomplete
        let r = AdminProxy.parse(Data((head + "abcde").utf8))
        XCTAssertEqual(r?.method, "POST")
        XCTAssertEqual(r?.path, "/admin/x?mount=/live")
        XCTAssertEqual(r?.headers["cookie"], "logikast=t")
        XCTAssertEqual(String(data: r?.body ?? Data(), encoding: .utf8), "abcde")
    }

    /// Needs a scratch Icecast with admin user "admin" and password "p@ss:w/rd#1 x" on LOGIKAST_PROXY_PORT.
    func testSignsInForTheBrowser() async throws {
        guard let text = ProcessInfo.processInfo.environment["LOGIKAST_PROXY_PORT"], let port = Int(text) else { throw XCTSkip("no scratch server") }
        let proxy = AdminProxy()
        let link = await proxy.start(target: .init(host: "127.0.0.1", port: port, user: "admin", password: "p@ss:w/rd#1 x"))
        let url = try XCTUnwrap(link)
        XCTAssertEqual(url.host, "127.0.0.1")

        // A "browser": follows the redirect and keeps the cookie, like Safari would.
        let config = URLSessionConfiguration.ephemeral
        let browser = URLSession(configuration: config)
        let (data, resp) = try await browser.data(from: url)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(resp.url?.path, "/admin/stats.xsl")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).lowercased().contains("icecast"))

        // Another page through the same session, and a client without the cookie is refused.
        let (_, second) = try await browser.data(from: URL(string: "http://127.0.0.1:\(url.port!)/admin/listmounts.xsl")!)
        XCTAssertEqual((second as? HTTPURLResponse)?.statusCode, 200)
        let stranger = URLSession(configuration: .ephemeral)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(url.port!)/admin/stats.xsl")!)
        req.httpShouldHandleCookies = false
        let (_, refused) = try await stranger.data(for: req)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 403)
        proxy.stop()
    }
}
