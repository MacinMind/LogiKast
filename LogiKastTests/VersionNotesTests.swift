import XCTest
@testable import LogiKast

final class VersionNotesTests: XCTestCase {
    // Shaped like the feed Feeder publishes, including its "You are subscribed" paragraph and a "</b" typo.
    private let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>LogiKast</title>
    <item><title>Version 1.0b3</title>
    <description><![CDATA[<p>You are subscribed to the <b>beta development releases</b>. Turn off <b>Include beta versions</b> in Server—Updates.</p>

    <b>Version 1.0b3</b
    <ul>
    <li>Added built-in updater</li>
    </ul>
    ]]></description>
    <sparkle:version>8</sparkle:version><sparkle:shortVersionString>1.0b3</sparkle:shortVersionString></item>
    <item><title>Version 1.0b2</title>
    <description><![CDATA[<p>You are subscribed to the <b>beta development releases</b>.</p><b>Version 1.0b2</b><ul><li>First beta</li></ul>]]></description>
    <sparkle:version>7</sparkle:version><sparkle:shortVersionString>1.0b2</sparkle:shortVersionString></item>
    <item><title>No notes</title><description><![CDATA[<p>Nothing useful</p>]]></description><sparkle:version>6</sparkle:version></item>
    </channel></rss>
    """

    func testMenuTitleFollowsTheFeed() {
        XCTAssertEqual(VersionNotes.menuTitle(includeBetas: true), "Beta Version Notes")
        XCTAssertEqual(VersionNotes.menuTitle(includeBetas: false), "Version Notes")
    }

    func testKeepsOnlyThePartFromBoldVersionOnward() {
        let notes = VersionNotes.notes(fromAppcast: Data(feed.utf8))
        XCTAssertEqual(notes.count, 2)                                  // the item without "<b>Version" is skipped
        XCTAssertTrue(notes[0].hasPrefix("<b>Version 1.0b3</b>"))        // newest first, "</b" typo repaired
        XCTAssertTrue(notes[0].contains("Added built-in updater"))
        XCTAssertTrue(notes[1].hasPrefix("<b>Version 1.0b2</b>"))
        XCTAssertFalse(notes.joined().contains("You are subscribed"))
    }

    func testNewestFirstByBuildNumberEvenWhenTheFeedOrderDiffers() {
        let reversed = """
        <rss xmlns:sparkle="x"><channel>
        <item><description><![CDATA[<b>Version A</b>]]></description><sparkle:version>9</sparkle:version></item>
        <item><description><![CDATA[<b>Version B</b>]]></description><sparkle:version>10</sparkle:version></item>
        </channel></rss>
        """
        XCTAssertEqual(VersionNotes.notes(fromAppcast: Data(reversed.utf8)), ["<b>Version B</b>", "<b>Version A</b>"])
    }

    func testEmptyAndBrokenFeeds() {
        XCTAssertTrue(VersionNotes.notes(fromAppcast: Data("<rss><channel/></rss>".utf8)).isEmpty)
        XCTAssertTrue(VersionNotes.notes(fromAppcast: Data("not xml".utf8)).isEmpty)
        XCTAssertNil(VersionNotes.notesPart(of: "<p>only the subscription message</p>"))
    }

    func testPageWrapsEachVersionAndKeepsHTML() {
        let page = VersionNotes.page(for: ["<b>Version 2</b><ul><li>x</li></ul>"])
        XCTAssertTrue(page.contains("color-scheme"))
        XCTAssertTrue(page.contains("<li>x</li>"))
    }
}
