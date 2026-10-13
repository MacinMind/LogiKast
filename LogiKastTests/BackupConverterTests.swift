import XCTest
@testable import LogiKast

final class BackupConverterTests: XCTestCase {
    private var dir: URL!
    private var dest: URL { dir.appendingPathComponent("backup") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("logikast-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// A short WAV file (two sine tones) at the given rate and channel count.
    private func wav(rate: Int, channels: Int, seconds: Int = 3, name: String = "tone.wav") throws -> URL {
        var pcm = Data()
        for i in 0..<(rate * seconds) {
            let t = Double(i) / Double(rate)
            let v = Int16(12000 * sin(2 * .pi * 440 * t) + 5000 * sin(2 * .pi * 1320 * t))
            for _ in 0..<channels { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        func le32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8((n >> (8 * $0)) & 0xFF) } }
        func le16(_ n: Int) -> [UInt8] { (0..<2).map { UInt8((n >> (8 * $0)) & 0xFF) } }
        var d = Data("RIFF".utf8) + Data(le32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + Data(le32(16)) + Data(le16(1)) + Data(le16(channels))
        d += Data(le32(rate)) + Data(le32(rate * channels * 2)) + Data(le16(channels * 2)) + Data(le16(16)) + Data("data".utf8) + Data(le32(pcm.count)) + pcm
        let url = dir.appendingPathComponent(name)
        try d.write(to: url)
        return url
    }

    private func seconds(_ stored: String, _ kind: AudioKind) throws -> Double {
        let data = try Data(contentsOf: dest.appendingPathComponent(stored), options: .alwaysMapped)
        return AudioFrames.parse(data, kind: kind).reduce(0) { $0 + $1.duration }
    }

    func testWavBecomesStandardMP3WhenThereIsNoLiveStream() throws {
        let installed = try BackupAudio.install(from: try wav(rate: 48000, channels: 1), mountName: "/live", into: dest)
        XCTAssertEqual(installed.storedName, "live-backup.mp3")
        XCTAssertEqual(installed.convertedTo, .standard)
        XCTAssertEqual(try seconds(installed.storedName, .mp3), 3, accuracy: 0.2)
        let info = try XCTUnwrap(BackupConverter.info(of: dest.appendingPathComponent(installed.storedName)))
        XCTAssertEqual(Int(info.sampleRate), 44100)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(BackupAudio.describe(stored: installed.storedName, in: dest), "MP3 · 44.1 kHz · stereo · about 128 kbps")
    }

    func testConvertsToTheLiveStreamsFormat() throws {
        let aac = BackupTarget(kind: .aac, sampleRate: 48000, channels: 1, bitrateKbps: 64)
        let installed = try BackupAudio.install(from: try wav(rate: 44100, channels: 2), mountName: "/live", target: aac, into: dest)
        XCTAssertEqual(installed.storedName, "live-backup.aac")
        XCTAssertEqual(try seconds(installed.storedName, .aac), 3, accuracy: 0.3)
        let info = try XCTUnwrap(BackupConverter.info(of: dest.appendingPathComponent(installed.storedName)))
        XCTAssertEqual(Int(info.sampleRate), 48000)
        XCTAssertEqual(info.channels, 1)
    }

    func testMatchingFileIsKeptAndOthersAreConverted() throws {
        let first = try BackupAudio.install(from: try wav(rate: 44100, channels: 2), mountName: "/a", into: dest)
        let stored = dest.appendingPathComponent(first.storedName)
        // Same format as the target: copied untouched.
        let same = try BackupAudio.install(from: stored, mountName: "/b", target: .standard, into: dest)
        XCTAssertNil(same.convertedTo)
        // Different sample rate: converted.
        let other = BackupTarget(kind: .mp3, sampleRate: 48000, channels: 2, bitrateKbps: 128)
        let converted = try BackupAudio.install(from: stored, mountName: "/c", target: other, into: dest)
        XCTAssertEqual(converted.convertedTo, other)
        // Already MP3 and no live stream to copy: kept as it is.
        XCTAssertNil(try BackupAudio.install(from: stored, mountName: "/d", target: nil, into: dest).convertedTo)
    }

    func testReconvertReplacesTheStoredFile() throws {
        let first = try BackupAudio.install(from: try wav(rate: 44100, channels: 2), mountName: "/live", into: dest)
        let aac = BackupTarget(kind: .aac, sampleRate: 44100, channels: 2, bitrateKbps: 96)
        let again = try BackupAudio.reconvert(stored: first.storedName, displayName: "tone.wav", mountName: "/live", target: aac, into: dest)
        XCTAssertEqual(again.storedName, "live-backup.aac")
        XCTAssertEqual(again.displayName, "tone.wav")
        XCTAssertFalse(BackupAudio.exists("live-backup.mp3", in: dest))
        XCTAssertTrue(BackupAudio.exists("live-backup.aac", in: dest))
        // Same format again: the stored file is replaced in place.
        let mp3 = BackupTarget(kind: .mp3, sampleRate: 32000, channels: 1, bitrateKbps: 64)
        _ = try BackupAudio.reconvert(stored: again.storedName, displayName: "tone.wav", mountName: "/live", target: mp3, into: dest)
        let redo = try BackupAudio.reconvert(stored: "live-backup.mp3", displayName: "tone.wav", mountName: "/live", target: .standard, into: dest)
        XCTAssertEqual(redo.storedName, "live-backup.mp3")
        XCTAssertEqual(Int(try XCTUnwrap(BackupConverter.info(of: dest.appendingPathComponent("live-backup.mp3"))).sampleRate), 44100)
    }

    func testUnreadableAndCanceledLeaveNothingBehind() throws {
        let junk = dir.appendingPathComponent("junk.bin")
        try Data((0..<4000).map { UInt8(($0 * 7) & 0xFF) }).write(to: junk)
        XCTAssertThrowsError(try BackupAudio.install(from: junk, mountName: "/a", into: dest)) {
            XCTAssertEqual($0 as? BackupAudio.BackupError, .cannotRead)
        }
        let flag = CancelFlag(); flag.cancel()
        XCTAssertThrowsError(try BackupAudio.install(from: try wav(rate: 44100, channels: 2), mountName: "/a", into: dest, cancel: flag)) {
            XCTAssertEqual($0 as? BackupAudio.BackupError, .cancelled)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []
        XCTAssertEqual(left, [])
    }

    /// HE-AAC (AAC+) is a different stream from plain AAC to a player: a plain AAC backup under an HE-AAC stream
    /// makes players stop. The backup has to be HE-AAC too.
    func testHEAACBackupMatchesAnHEAACStream() throws {
        let he = BackupTarget(kind: .aac, sampleRate: 44100, channels: 2, bitrateKbps: 64, highEfficiency: true)
        let installed = try BackupAudio.install(from: try wav(rate: 44100, channels: 2), mountName: "/live", target: he, into: dest)
        XCTAssertEqual(installed.storedName, "live-backup-he.aac")
        XCTAssertTrue(BackupAudio.isHighEfficiency(installed.storedName))
        let url = dest.appendingPathComponent(installed.storedName)
        // Like a live HE-AAC encoder: the ADTS headers say 22.05 kHz, the audio is 44.1 kHz.
        let head = try Data(contentsOf: url).prefix(4)
        XCTAssertEqual((head[head.startIndex + 2] >> 2) & 0x0F, 7)
        XCTAssertEqual(Int(try XCTUnwrap(BackupConverter.info(of: url)).sampleRate), 44100)
        XCTAssertTrue(BackupAudio.looksHighEfficiency(adtsHead: head, playbackRate: 44100))
        XCTAssertEqual(try seconds(installed.storedName, .aac), 3, accuracy: 0.3)
        XCTAssertEqual(BackupAudio.describe(stored: installed.storedName, in: dest)?.hasPrefix("HE-AAC · 44.1 kHz · stereo"), true)

        // The feeder announces it as audio/aacp, and a plain AAC backup as audio/aac.
        var c = AppConfig.makeDefault()
        c.mounts[0].name = "/live"; c.mounts[0].backupFile = installed.storedName
        XCTAssertEqual(BackupFeeds.make(for: c, backupDir: dest, fileExists: { _ in true }).feeds.first?.contentType, "audio/aacp")

        // The same HE-AAC file is kept for an HE-AAC stream, and replaced for a plain AAC one.
        XCTAssertNil(try BackupAudio.install(from: url, mountName: "/x", target: he, into: dest).convertedTo)
        let lc = BackupTarget(kind: .aac, sampleRate: 44100, channels: 2, bitrateKbps: 128)
        let plain = try BackupAudio.install(from: url, mountName: "/live", target: lc, into: dest)
        XCTAssertEqual(plain.storedName, "live-backup.aac")
        XCTAssertFalse(BackupAudio.exists("live-backup-he.aac", in: dest))
        c.mounts[0].backupFile = plain.storedName
        XCTAssertEqual(BackupFeeds.make(for: c, backupDir: dest, fileExists: { _ in true }).feeds.first?.contentType, "audio/aac")
    }

    func testTargetFromLiveStatus() {
        var live = MountStatus(path: "/live", listeners: 0, peak: 0)
        live.contentType = "audio/aacp"; live.sampleRate = 48000; live.channels = 2; live.bitrate = 96
        XCTAssertEqual(BackupTarget.matching(live), BackupTarget(kind: .aac, sampleRate: 48000, channels: 2, bitrateKbps: 96, highEfficiency: true))
        live.contentType = "audio/aac"
        XCTAssertEqual(BackupTarget.matching(live), BackupTarget(kind: .aac, sampleRate: 48000, channels: 2, bitrateKbps: 96))
        live.contentType = "audio/mpeg"; live.sampleRate = 96000; live.channels = nil; live.bitrate = nil
        XCTAssertEqual(BackupTarget.matching(live), BackupTarget(kind: .mp3, sampleRate: 48000, channels: 2, bitrateKbps: 128))
        live.contentType = "audio/ogg"
        XCTAssertNil(BackupTarget.matching(live))
    }

    func testStatusReportsSampleRateAndChannels() throws {
        let json = #"{"icestats":{"server_id":"Icecast 2.5.0","source":{"listenurl":"http://localhost:8000/live","server_type":"audio/mpeg","stream_start_iso8601":"2026-10-13T10:00:00-0400","audio_info":"ice-samplerate=48000;ice-bitrate=128;ice-channels=1","listeners":0,"listener_peak":0}}}"#
        let status = try XCTUnwrap(StatusParser.parse(Data(json.utf8)))
        let m = try XCTUnwrap(status.mounts.first)
        XCTAssertEqual(m.sampleRate, 48000)
        XCTAssertEqual(m.channels, 1)
        XCTAssertEqual(m.bitrate, 128)
    }
}
