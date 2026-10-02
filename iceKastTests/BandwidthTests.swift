import XCTest
@testable import iceKast

final class BandwidthTests: XCTestCase {
    func testRateFromCounters() {
        var m = BandwidthMeter()
        let t0 = Date()
        XCTAssertNil(m.update(["/live": ByteCounters(sent: 1_000, read: 100)], at: t0))
        let r = m.update(["/live": ByteCounters(sent: 1_000 + 800_000, read: 100 + 8_000)], at: t0.addingTimeInterval(2))!
        XCTAssertEqual(r.out["/live"]!, 3_200_000, accuracy: 1)      // 800 kB in 2 s = 3.2 Mb/s
        XCTAssertEqual(r.into["/live"]!, 32_000, accuracy: 1)
    }

    func testBurstyEncoderIsSmoothed() {
        var m = BandwidthMeter()
        let t0 = Date()
        var sent: UInt64 = 0
        var last: BandwidthRates?
        // 64 kb/s on average, but delivered as 32 kB every 4 s, so single 2 s steps read 0 or 128 kb/s.
        for step in 0...10 {
            if step % 2 == 0 { sent += 32_000 }
            last = m.update(["/live": ByteCounters(sent: sent, read: 0)], at: t0.addingTimeInterval(Double(step) * 2)) ?? last
        }
        XCTAssertEqual(last!.out["/live"]!, 64_000, accuracy: 16_000)
    }

    func testCounterResetAndNewMountAreSkipped() {
        var m = BandwidthMeter()
        let t0 = Date()
        _ = m.update(["/a": ByteCounters(sent: 5_000, read: 5_000)], at: t0)
        let r = m.update(["/a": ByteCounters(sent: 10, read: 10), "/b": ByteCounters(sent: 99, read: 99)], at: t0.addingTimeInterval(2))!
        XCTAssertNil(r.out["/a"])
        XCTAssertNil(r.out["/b"])
    }

    func testResetForgetsHistory() {
        var m = BandwidthMeter()
        let t0 = Date()
        _ = m.update(["/a": ByteCounters(sent: 0, read: 0)], at: t0)
        m.reset()
        XCTAssertNil(m.update(["/a": ByteCounters(sent: 9_999_999, read: 0)], at: t0.addingTimeInterval(60)))
    }

    func testMountTotalsIncludeBackupAndServerTotalSumsAll() {
        let r = BandwidthRates(out: ["/live": 1_000_000, BackupAudio.internalMount(forMount: "/live"): 250_000, "/jazz": 500_000], into: ["/live": 64_000])
        XCTAssertEqual(r.outgoing(mount: "/live"), 1_250_000)
        XCTAssertEqual(r.outgoing(mount: "/jazz"), 500_000)
        XCTAssertNil(r.outgoing(mount: "/none"))
        XCTAssertEqual(r.totalOut, 1_750_000)
    }

    func testFormat() {
        XCTAssertEqual(BandwidthRates.format(64_000).value, "64")
        XCTAssertEqual(BandwidthRates.format(64_000).unit, "kb/s")
        XCTAssertEqual(BandwidthRates.format(1_820_000).value, "1.82")
        XCTAssertEqual(BandwidthRates.format(1_820_000).unit, "Mb/s")
        XCTAssertEqual(BandwidthRates.format(64_000_000).value, "64.0")
        XCTAssertEqual(BandwidthRates.format(0).value, "0")
    }

    func testParsesCountersFromAdminStats() {
        let xml = """
        <icestats><source mount="/live"><total_bytes_read>200</total_bytes_read><total_bytes_sent>900</total_bytes_sent></source>
        <source mount="/_backup/live"><total_bytes_sent>50</total_bytes_sent></source>
        <source mount="/odd"><listeners>0</listeners></source></icestats>
        """
        let c = AdminStats.byteCounters(from: Data(xml.utf8))
        XCTAssertEqual(c["/live"], ByteCounters(sent: 900, read: 200))
        XCTAssertEqual(c["/_backup/live"], ByteCounters(sent: 50, read: 0))
        XCTAssertNil(c["/odd"])
    }
}
