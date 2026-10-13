import Foundation
import AudioToolbox

/// What a backup file should be, so listeners can switch to it and back without the player noticing.
struct BackupTarget: Equatable {
    var kind: BackupAudio.Kind
    var sampleRate: Int
    var channels: Int          // 1 or 2
    var bitrateKbps: Int

    /// Used when there is no live stream to copy: the most widely played MP3 settings.
    static let standard = BackupTarget(kind: .mp3, sampleRate: 44100, channels: 2, bitrateKbps: 128)

    /// Copies the format of a stream that is on the air. Anything the server doesn't report is filled in with `standard`.
    static func matching(_ live: MountStatus) -> BackupTarget? {
        guard let type = live.contentType.flatMap(StreamFormat.init(contentType:)) else { return nil }
        let kind: BackupAudio.Kind = type.isAAC ? .aac : .mp3
        let rate = live.sampleRate.flatMap { $0 > 0 ? $0 : nil } ?? standard.sampleRate
        let channels = min(max(live.channels ?? standard.channels, 1), 2)
        return BackupTarget(kind: kind, sampleRate: kind == .mp3 ? BackupConverter.nearestMP3Rate(rate) : rate,
                            channels: channels, bitrateKbps: live.bitrate.flatMap { $0 > 0 ? $0 : nil } ?? standard.bitrateKbps)
    }

    var summary: String {
        "\(kind.label) · \(BackupAudio.rateText(sampleRate)) · \(channels == 1 ? "mono" : "stereo") · \(bitrateKbps) kbps"
    }
}

/// Lets the window's Cancel button stop a conversion that is running on another thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

/// Converts any audio file macOS can read to MP3 (with LAME) or AAC (ADTS, with macOS's own encoder).
enum BackupConverter {
    static let mp3Rates = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
    static let mp3Bitrates = [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]

    static func nearestMP3Rate(_ rate: Int) -> Int { mp3Rates.min { abs($0 - rate) < abs($1 - rate) } ?? 44100 }

    struct Info: Equatable {
        var sampleRate: Double
        var channels: Int
        var seconds: Double
    }

    /// Sample rate, channels and length of an audio file, or nil if macOS can't read it.
    static func info(of url: URL) -> Info? {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file else { return nil }
        defer { ExtAudioFileDispose(file) }
        guard let format = fileFormat(file) else { return nil }
        var frames: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
        let rate = format.mSampleRate
        return Info(sampleRate: rate, channels: Int(format.mChannelsPerFrame), seconds: rate > 0 ? Double(frames) / rate : 0)
    }

    private static func fileFormat(_ file: ExtAudioFileRef) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr else { return nil }
        return format
    }

    /// Writes `source` to `dest` in the target format. `progress` is called with 0...1. Throws `.cancelled` if
    /// `cancel` is set, `.cannotRead` if macOS can't open or decode the file.
    static func convert(from source: URL, to dest: URL, target: BackupTarget,
                        cancel: CancelFlag = CancelFlag(), progress: (Double) -> Void = { _ in }) throws {
        var srcRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(source as CFURL, &srcRef) == noErr, let src = srcRef else { throw BackupAudio.BackupError.cannotRead }
        defer { ExtAudioFileDispose(src) }
        guard let fileFormat = fileFormat(src), fileFormat.mChannelsPerFrame > 0 else { throw BackupAudio.BackupError.cannotRead }
        var totalFrames: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(src, kExtAudioFileProperty_FileLengthFrames, &size, &totalFrames)

        // What we hand the encoder: 16-bit interleaved audio at the target rate and channel count. macOS resamples
        // and mixes channels on the way.
        let channels = UInt32(target.channels)
        var pcm = AudioStreamBasicDescription(
            mSampleRate: Float64(target.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        guard ExtAudioFileSetProperty(src, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm) == noErr
        else { throw BackupAudio.BackupError.cannotRead }

        let sink: Sink
        switch target.kind {
        case .mp3: sink = try MP3Sink(to: dest, target: target)
        case .aac: sink = try AACSink(to: dest, target: target, pcm: &pcm)
        }

        let chunkFrames: UInt32 = 8192
        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(chunkFrames * channels))
        defer { buffer.deallocate() }
        do {
            while true {
                if cancel.isCancelled { throw BackupAudio.BackupError.cancelled }
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: channels, mDataByteSize: chunkFrames * 2 * channels, mData: UnsafeMutableRawPointer(buffer)))
                var frames = chunkFrames
                guard ExtAudioFileRead(src, &frames, &list) == noErr else { throw BackupAudio.BackupError.cannotRead }
                if frames == 0 { break }
                try sink.write(buffer, frames: Int(frames))
                if totalFrames > 0 {
                    var position: Int64 = 0
                    if ExtAudioFileTell(src, &position) == noErr { progress(min(1, Double(position) / Double(totalFrames))) }
                }
            }
            try sink.finish()
        } catch {
            sink.abandon()
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        progress(1)
    }
}

private protocol Sink: AnyObject {
    func write(_ samples: UnsafeMutablePointer<Int16>, frames: Int) throws
    func finish() throws
    func abandon()
}

private final class MP3Sink: Sink {
    private var encoder: lame_t?
    private let handle: FileHandle
    private let channels: Int
    private var out = [UInt8]()

    init(to url: URL, target: BackupTarget) throws {
        guard let gf = lame_init() else { throw BackupAudio.BackupError.conversionFailed("The MP3 encoder didn't start.") }
        let rate = BackupConverter.nearestMP3Rate(target.sampleRate)
        let kbps = BackupConverter.mp3Bitrates.min { abs($0 - target.bitrateKbps) < abs($1 - target.bitrateKbps) } ?? 128
        lame_set_in_samplerate(gf, Int32(target.sampleRate))
        lame_set_out_samplerate(gf, Int32(rate))
        lame_set_num_channels(gf, Int32(target.channels))
        lame_set_mode(gf, target.channels == 1 ? MONO : JOINT_STEREO)
        lame_set_brate(gf, Int32(kbps))
        lame_set_VBR(gf, vbr_off)              // constant bitrate: what a live stream sends
        lame_set_quality(gf, 2)
        lame_set_write_id3tag_automatic(gf, 0)  // the file starts straight with audio, like a live stream
        guard lame_init_params(gf) >= 0 else {
            lame_close(gf)
            throw BackupAudio.BackupError.conversionFailed("The MP3 encoder doesn't support those settings.")
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            lame_close(gf)
            throw BackupAudio.BackupError.conversionFailed("The converted file couldn't be saved.")
        }
        self.encoder = gf; self.handle = handle; self.channels = target.channels
    }

    deinit { if let encoder { lame_close(encoder) } }

    func write(_ samples: UnsafeMutablePointer<Int16>, frames: Int) throws {
        guard let encoder else { return }
        let needed = frames * 5 / 4 + 7200
        if out.count < needed { out = [UInt8](repeating: 0, count: needed) }
        let n = out.withUnsafeMutableBufferPointer { lame_encode_buffer_interleaved(encoder, samples, Int32(frames), $0.baseAddress, Int32(needed)) }
        guard n >= 0 else { throw BackupAudio.BackupError.conversionFailed("The MP3 encoder stopped (error \(n)).") }
        if n > 0 { try handle.write(contentsOf: out[0..<Int(n)]) }
    }

    func finish() throws {
        guard let encoder else { return }
        if out.count < 7200 { out = [UInt8](repeating: 0, count: 7200) }
        let n = out.withUnsafeMutableBufferPointer { lame_encode_flush(encoder, $0.baseAddress, Int32(7200)) }
        if n > 0 { try handle.write(contentsOf: out[0..<Int(n)]) }
        try handle.close()
    }

    func abandon() { try? handle.close() }
}

private final class AACSink: Sink {
    private var file: ExtAudioFileRef?

    init(to url: URL, target: BackupTarget, pcm: inout AudioStreamBasicDescription) throws {
        var aac = AudioStreamBasicDescription(
            mSampleRate: Float64(target.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(target.channels), mBitsPerChannel: 0, mReserved: 0)
        var ref: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAAC_ADTSType, &aac, nil,
                                        AudioFileFlags.eraseFile.rawValue, &ref) == noErr, let ref else {
            throw BackupAudio.BackupError.conversionFailed("The AAC encoder doesn't support those settings.")
        }
        file = ref
        guard ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm) == noErr else {
            ExtAudioFileDispose(ref); file = nil
            throw BackupAudio.BackupError.conversionFailed("The AAC encoder doesn't support those settings.")
        }
        // Ask for the stream's bitrate, or the nearest one the encoder offers for this rate and channel count.
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        if ExtAudioFileGetProperty(ref, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr, let converter {
            var want = UInt32(target.bitrateKbps * 1000)
            var rangesSize: UInt32 = 0
            if AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &rangesSize, nil) == noErr, rangesSize > 0 {
                var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(rangesSize) / MemoryLayout<AudioValueRange>.size)
                if AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &rangesSize, &ranges) == noErr, !ranges.isEmpty {
                    let w = Double(want)
                    let best = ranges.map { min(max(w, $0.mMinimum), $0.mMaximum) }.min { abs($0 - w) < abs($1 - w) } ?? w
                    want = UInt32(best)
                }
            }
            AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &want)
            var config: UnsafeRawPointer? = nil      // "no configuration": tells the file the converter was changed
            ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<UnsafeRawPointer?>.size), &config)
        }
    }

    deinit { if let file { ExtAudioFileDispose(file) } }

    func write(_ samples: UnsafeMutablePointer<Int16>, frames: Int) throws {
        guard let file else { return }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 0, mDataByteSize: 0, mData: UnsafeMutableRawPointer(samples)))
        // Describe exactly the bytes we hold: the caller's buffer holds `frames` interleaved 16-bit frames.
        var info = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_ClientDataFormat, &size, &info)
        list.mBuffers.mNumberChannels = info.mChannelsPerFrame
        list.mBuffers.mDataByteSize = UInt32(frames) * info.mBytesPerFrame
        guard ExtAudioFileWrite(file, UInt32(frames), &list) == noErr else {
            throw BackupAudio.BackupError.conversionFailed("The AAC encoder stopped.")
        }
    }

    func finish() throws {
        guard let file else { return }
        self.file = nil
        guard ExtAudioFileDispose(file) == noErr else { throw BackupAudio.BackupError.conversionFailed("The converted file couldn't be saved.") }
    }

    func abandon() { if let file { ExtAudioFileDispose(file); self.file = nil } }
}
