import XCTest
@testable import LogiKast

final class UpdaterTests: XCTestCase {
    func testFeedFollowsTheBetaSwitch() {
        XCTAssertEqual(UpdateFeed.url(includeBetas: false), "https://macinmind.com/pads/LogiKast.xml")
        XCTAssertEqual(UpdateFeed.url(includeBetas: true), "https://macinmind.com/pads/LogiKastbeta.xml")
    }

    func testBetaVersionsAreRecognized() {
        XCTAssertTrue(UpdateFeed.isBeta(version: "1.0b3"))
        XCTAssertTrue(UpdateFeed.isBeta(version: "2.1b12"))
        XCTAssertFalse(UpdateFeed.isBeta(version: "1.0"))
        XCTAssertFalse(UpdateFeed.isBeta(version: "1.0.1"))
        XCTAssertFalse(UpdateFeed.isBeta(version: ""))
    }

    /// Sparkle compares CFBundleVersion, so every later release (beta or final) must sort higher.
    func testInternalBuildNumbersSortInReleaseOrder() {
        let order = ["1.0.0.7.2", "1.0.0.8.3", "1.0.0.9.3", "1.0.0.10.0", "1.0.1.11.0", "1.1.0.12.1"]
        for (a, b) in zip(order, order.dropFirst()) {
            XCTAssertEqual(a.compare(b, options: .numeric), .orderedAscending, "\(a) should be older than \(b)")
        }
    }
}
