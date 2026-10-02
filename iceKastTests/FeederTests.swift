import XCTest
@testable import iceKast

final class AudioFramesTests: XCTestCase {
    /// An MPEG-1 Layer III frame: 128 kbps, 44.1 kHz -> 417 bytes (418 with padding), 26.12 ms.
    private func mp3Frame(padding: Bool = false) -> [UInt8] {
        let length = 144 * 128_000 / 44_100 + (padding ? 1 : 0)
        var f = [UInt8](repeating: 0, count: length)
        f[0] = 0xFF; f[1] = 0xFB; f[2] = 0x90 | (padding ? 0x02 : 0); f[3] = 0x00
        return f
    }

    /// An ADTS frame: AAC-LC, 44.1 kHz, `length` bytes (header included), one raw data block.
    private func adtsFrame(length: Int = 200) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: length)
        f[0] = 0xFF; f[1] = 0xF1; f[2] = 0x50                       // sync, MPEG-4, protection absent; AAC-LC, 44.1k
        f[3] = UInt8((length >> 11) & 0x03)
        f[4] = UInt8((length >> 3) & 0xFF)
        f[5] = UInt8((length & 0x07) << 5) | 0x1F
        f[6] = 0xFC
        return f
    }

    func testMP3FramesAndDuration() {
        let data = Data((0..<100).flatMap { _ in mp3Frame() })
        let frames = AudioFrames.parse(data, kind: .mp3)
        XCTAssertEqual(frames.count, 100)
        XCTAssertEqual(frames[0].length, 417)
        XCTAssertEqual(frames[1].offset, 417)
        XCTAssertEqual(frames.reduce(0) { $0 + $1.duration }, 100 * 1152.0 / 44100, accuracy: 0.0001)
    }

    func testMP3PaddingChangesFrameLength() {
        let data = Data(mp3Frame() + mp3Frame(padding: true) + mp3Frame())
        let frames = AudioFrames.parse(data, kind: .mp3)
        XCTAssertEqual(frames.map(\.length), [417, 418, 417])
    }

    func testID3TagsAreSkipped() {
        var id3 = [UInt8]("ID3".utf8) + [4, 0, 0, 0, 0, 0, 0x14]      // v2.4, size = 20 (syncsafe)
        id3 += [UInt8](repeating: 0x41, count: 20)
        let tail = [UInt8](repeating: 0x20, count: 128)
        var v1 = tail; v1[0] = 0x54; v1[1] = 0x41; v1[2] = 0x47        // ID3v1 "TAG"
        let data = Data(id3 + mp3Frame() + mp3Frame() + v1)
        let frames = AudioFrames.parse(data, kind: .mp3)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].offset, 30)
    }

    func testGarbageAndTruncationAreHandled() {
        XCTAssertTrue(AudioFrames.parse(Data([1, 2, 3, 4, 5]), kind: .mp3).isEmpty)
        XCTAssertTrue(AudioFrames.parse(Data(), kind: .aac).isEmpty)
        let cut = Data(mp3Frame() + mp3Frame() + mp3Frame().prefix(100))     // last frame truncated
        XCTAssertEqual(AudioFrames.parse(cut, kind: .mp3).count, 2)
        let noise = Data(mp3Frame() + [UInt8](repeating: 0xFF, count: 50) + mp3Frame())   // false syncs in between
        XCTAssertGreaterThanOrEqual(AudioFrames.parse(noise, kind: .mp3).count, 1)
    }

    func testADTSFramesAndDuration() {
        let data = Data((0..<50).flatMap { _ in adtsFrame() })
        let frames = AudioFrames.parse(data, kind: .aac)
        XCTAssertEqual(frames.count, 50)
        XCTAssertEqual(frames[0].length, 200)
        XCTAssertEqual(frames.reduce(0) { $0 + $1.duration }, 50 * 1024.0 / 44100, accuracy: 0.0001)
    }

    func testMP3DataIsNotParsedAsAAC() {
        XCTAssertTrue(AudioFrames.parse(Data(mp3Frame() + mp3Frame()), kind: .aac).isEmpty)
    }

    func testPacerSendsAtRealTimeSpeedWithASmallLead() {
        var p = Pacer(lead: 1.0)
        // 0.026 s frames: the first ~1 s goes out immediately, then one frame per 26 ms of wall time.
        var immediate = 0, t = 0.0
        for _ in 0..<200 {
            let wait = p.delay(forFrameDuration: 0.026, elapsed: t)
            if wait == 0 && t == 0 { immediate += 1 }
            t += wait
        }
        XCTAssertEqual(immediate, 39, accuracy: 2)                    // ~1 s worth up front
        XCTAssertEqual(t, 200 * 0.026 - 1.0, accuracy: 0.05)          // the rest is paced in real time
        XCTAssertEqual(p.audioSent, 5.2, accuracy: 0.001)
    }

    func testPacerNeverWaitsWhenItIsBehind() {
        var p = Pacer(lead: 1.0)
        _ = p.delay(forFrameDuration: 0.5, elapsed: 0)
        XCTAssertEqual(p.delay(forFrameDuration: 0.5, elapsed: 10), 0)   // a stall: catch up, don't sleep
    }
}
