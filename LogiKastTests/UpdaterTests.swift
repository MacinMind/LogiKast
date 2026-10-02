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

    /// Sparkle compares CFBundleVersion (a plain build number), so each later release must have a higher one.
    func testBuildNumbersAreWholeNumbersThatSortInReleaseOrder() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        XCTAssertNotNil(Int(build), "CFBundleVersion must be a whole number, got \(build)")
        for (a, b) in [("8", "9"), ("9", "10"), ("99", "100")] {
            XCTAssertEqual(a.compare(b, options: .numeric), .orderedAscending)
        }
    }
}
