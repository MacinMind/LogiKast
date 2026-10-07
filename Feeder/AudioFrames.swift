import Foundation

/// One audio frame inside an MP3 or AAC (ADTS) file, and how long it plays.
struct AudioFrame: Equatable {
    var offset: Int
    var length: Int
    var duration: Double          // seconds
}

enum AudioKind: Equatable {
    case mp3
    case aac
}

/// Splits MP3 and ADTS-AAC files into frames so they can be sent at real-time speed.
enum AudioFrames {
    /// Reads the bytes in place: a long backup file is not copied (a copy is as large as the file again).
    static func parse(_ data: Data, kind: AudioKind) -> [AudioFrame] {
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            return kind == .mp3 ? parseMP3(b) : parseADTS(b)
        }
    }

    // MARK: MP3

    private static let mpeg1Rates = [44100, 48000, 32000]
    private static let mpeg2Rates = [22050, 24000, 16000]
    private static let mpeg25Rates = [11025, 12000, 8000]
    private static let br1L1 = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
    private static let br1L2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
    private static let br1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let br2L1 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
    private static let br2L23 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    /// Length and duration of the MP3 frame whose header starts at `i`, or nil if it isn't a valid header.
    static func mp3Header(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> (length: Int, duration: Double)? {
        guard i + 4 <= b.count, b[i] == 0xFF, (b[i + 1] & 0xE0) == 0xE0 else { return nil }
        let version = Int((b[i + 1] >> 3) & 3)          // 0: 2.5, 1: reserved, 2: MPEG-2, 3: MPEG-1
        let layer = Int((b[i + 1] >> 1) & 3)            // 1: III, 2: II, 3: I, 0: reserved
        let brIndex = Int(b[i + 2] >> 4)
        let srIndex = Int((b[i + 2] >> 2) & 3)
        let padding = Int((b[i + 2] >> 1) & 1)
        guard version != 1, layer != 0, brIndex != 0, brIndex != 15, srIndex != 3 else { return nil }
        let mpeg1 = version == 3
        let rate = (mpeg1 ? mpeg1Rates : (version == 2 ? mpeg2Rates : mpeg25Rates))[srIndex]
        let kbps: Int
        switch (layer, mpeg1) {
        case (3, true): kbps = br1L1[brIndex]
        case (2, true): kbps = br1L2[brIndex]
        case (1, true): kbps = br1L3[brIndex]
        case (3, false): kbps = br2L1[brIndex]
        default: kbps = br2L23[brIndex]
        }
        let bitrate = kbps * 1000
        let samples: Int, length: Int
        if layer == 3 {                                  // Layer I
            samples = 384
            length = (12 * bitrate / rate + padding) * 4
        } else if layer == 2 || mpeg1 {                  // Layer II, or MPEG-1 Layer III
            samples = 1152
            length = 144 * bitrate / rate + padding
        } else {                                         // MPEG-2/2.5 Layer III
            samples = 576
            length = 72 * bitrate / rate + padding
        }
        guard length >= 4 else { return nil }
        return (length, Double(samples) / Double(rate))
    }

    private static func parseMP3(_ b: UnsafeBufferPointer<UInt8>) -> [AudioFrame] {
        var pos = 0
        if b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {          // ID3v2 tag: skip it
            let size = (Int(b[6] & 0x7F) << 21) | (Int(b[7] & 0x7F) << 14) | (Int(b[8] & 0x7F) << 7) | Int(b[9] & 0x7F)
            let footer = (b[5] & 0x10) != 0 ? 10 : 0
            pos = 10 + size + footer
        }
        var frames: [AudioFrame] = []
        while pos + 4 <= b.count {
            if b.count - pos == 128, b[pos] == 0x54, b[pos + 1] == 0x41, b[pos + 2] == 0x47 { break }   // ID3v1 tag at the end
            guard let h = mp3Header(b, at: pos), pos + h.length <= b.count else { pos += 1; continue }
            // A real frame is followed by another frame (or the end); otherwise this was a false sync.
            let next = pos + h.length
            if next + 4 <= b.count, mp3Header(b, at: next) == nil, !(b.count - next == 128 && b[next] == 0x54) {
                pos += 1; continue
            }
            frames.append(AudioFrame(offset: pos, length: h.length, duration: h.duration))
            pos = next
        }
        return frames
    }

    // MARK: AAC (ADTS)

    private static let aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    static func adtsHeader(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> (length: Int, duration: Double)? {
        guard i + 7 <= b.count, b[i] == 0xFF, (b[i + 1] & 0xF6) == 0xF0 else { return nil }   // sync, layer 00
        let srIndex = Int((b[i + 2] >> 2) & 0x0F)
        guard srIndex < aacRates.count else { return nil }
        let length = (Int(b[i + 3] & 0x03) << 11) | (Int(b[i + 4]) << 3) | Int(b[i + 5] >> 5)
        let blocks = Int(b[i + 6] & 0x03) + 1
        guard length >= 7 else { return nil }
        return (length, Double(1024 * blocks) / Double(aacRates[srIndex]))
    }

    private static func parseADTS(_ b: UnsafeBufferPointer<UInt8>) -> [AudioFrame] {
        var pos = 0
        if b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {
            let size = (Int(b[6] & 0x7F) << 21) | (Int(b[7] & 0x7F) << 14) | (Int(b[8] & 0x7F) << 7) | Int(b[9] & 0x7F)
            pos = 10 + size
        }
        var frames: [AudioFrame] = []
        while pos + 7 <= b.count {
            guard let h = adtsHeader(b, at: pos), pos + h.length <= b.count else { pos += 1; continue }
            let next = pos + h.length
            if next + 7 <= b.count, adtsHeader(b, at: next) == nil { pos += 1; continue }
            frames.append(AudioFrame(offset: pos, length: h.length, duration: h.duration))
            pos = next
        }
        return frames
    }
}

/// Decides how long to wait before sending each frame so audio goes out at normal playback speed,
/// staying `lead` seconds ahead of real time (like an encoder with a small buffer).
struct Pacer {
    var lead: Double = 1.0
    private(set) var audioSent: Double = 0

    /// - Parameter elapsed: wall-clock seconds since streaming started.
    mutating func delay(forFrameDuration duration: Double, elapsed: Double) -> Double {
        let wait = max(0, audioSent - lead - elapsed)
        audioSent += duration
        return wait
    }
}
