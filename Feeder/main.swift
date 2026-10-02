// icekast-feeder: streams each mount's backup audio file to the local Icecast server at normal
// playback speed (like a live encoder), looping forever. Icecast's own file fallback sends files
// far faster than real time, so listeners end up playing a big backlog after the live stream
// returns; a real-time source avoids that. Runs under the same launchd job as Icecast.
import Foundation
import Darwin

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let support = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/Library/Application Support/iceKast"
let feedsPath = support + "/backup-feeds.json"
let statusPath = support + "/backup-status.json"

func monotonic() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

func connectTCP(host: String, port: Int) -> Int32? {
    var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { return nil }
    defer { freeaddrinfo(res) }
    var p: UnsafeMutablePointer<addrinfo>? = first
    while let ai = p {
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        if fd >= 0 {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { return fd }
            close(fd)
        }
        p = ai.pointee.ai_next
    }
    return nil
}

func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
    var sent = 0
    while sent < bytes.count {
        let n = write(fd, bytes.baseAddress! + sent, bytes.count - sent)
        if n < 0 { if errno == EINTR { continue }; return false }
        if n == 0 { return false }
        sent += n
    }
    return true
}

/// Reads the HTTP response header (up to the blank line); returns the status line.
func readStatusLine(_ fd: Int32, timeout: Int32 = 5000) -> String? {
    var buf = [UInt8](), tmp = [UInt8](repeating: 0, count: 512)
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while buf.count < 4096 {
        guard poll(&pfd, 1, timeout) > 0 else { return nil }
        let n = read(fd, &tmp, tmp.count)
        if n <= 0 { return nil }
        buf += tmp[0..<n]
        if let s = String(bytes: buf, encoding: .utf8), s.contains("\r\n\r\n") || s.contains("\n\n") {
            return s.split(whereSeparator: \.isNewline).first.map(String.init)
        }
    }
    return nil
}

final class Worker {
    let feed: BackupFeedsFile.Feed, host: String, port: Int, password: String
    private let lock = NSLock()
    private var _state = "connecting", _detail = "", _cancelled = false

    init(feed: BackupFeedsFile.Feed, host: String, port: Int, password: String) {
        self.feed = feed; self.host = host; self.port = port; self.password = password
    }

    var snapshot: BackupFeederStatus.FeedState {
        lock.lock(); defer { lock.unlock() }
        return .init(mount: feed.mount, state: _state, detail: _detail)
    }
    private func set(_ s: String, _ d: String = "") { lock.lock(); _state = s; _detail = d; lock.unlock() }
    private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    func start() { Thread.detachNewThread { [self] in run() } }

    private func run() {
        while !cancelled {
            stream()
            var waited = 0.0
            while !cancelled, waited < 2 { Thread.sleep(forTimeInterval: 0.1); waited += 0.1 }
        }
    }

    private func sleepCancellable(_ seconds: Double) {
        var left = seconds
        while left > 0, !cancelled { let s = min(left, 0.2); Thread.sleep(forTimeInterval: s); left -= s }
    }

    private func stream() {
        set("connecting")
        guard let data = FileManager.default.contents(atPath: feed.file) else { set("error", "The backup audio file is missing."); return }
        let kind: AudioKind = feed.contentType == "audio/mpeg" ? .mp3 : .aac
        let frames = AudioFrames.parse(data, kind: kind)
        guard !frames.isEmpty else { set("error", "No audio was found in the backup file."); return }
        guard let fd = connectTCP(host: host, port: port) else { set("error", "Can't reach the server."); return }
        defer { close(fd) }

        let auth = Data("source:\(password)".utf8).base64EncodedString()
        let header = "SOURCE \(feed.mount) HTTP/1.0\r\nAuthorization: Basic \(auth)\r\nContent-Type: \(feed.contentType)\r\n"
            + "ice-name: \(feed.name)\r\nice-public: 0\r\nUser-Agent: iceKast-backup\r\n\r\n"
        guard Array(header.utf8).withUnsafeBytes({ writeAll(fd, $0) }) else { set("error", "Lost the connection to the server."); return }
        guard let status = readStatusLine(fd) else { set("error", "The server did not answer."); return }
        guard status.contains(" 200") else {
            set("error", status.contains("401") ? "The server refused the encoder password." : "The server refused the backup stream (\(status)).")
            return
        }
        set("streaming")

        var pacer = Pacer()
        let start = monotonic()
        data.withUnsafeBytes { raw in
            while !cancelled {
                for f in frames {
                    if cancelled { return }
                    let wait = pacer.delay(forFrameDuration: f.duration, elapsed: monotonic() - start)
                    if wait > 0 { sleepCancellable(wait) }
                    if cancelled { return }
                    if !writeAll(fd, UnsafeRawBufferPointer(rebasing: raw[f.offset..<(f.offset + f.length)])) {
                        set("error", "Lost the connection to the server.")
                        return
                    }
                }
            }
        }
    }
}

// MARK: main loop

var workers: [String: Worker] = [:]
var lastFeedsStamp: Date?

func key(_ f: BackupFeedsFile.Feed, _ cfg: BackupFeedsFile) -> String {
    "\(cfg.host):\(cfg.port)|\(cfg.password)|\(f.mount)|\(f.file)|\(f.contentType)"
}

func reloadFeeds() {
    let attrs = try? FileManager.default.attributesOfItem(atPath: feedsPath)
    let stamp = attrs?[.modificationDate] as? Date
    guard stamp != lastFeedsStamp else { return }
    lastFeedsStamp = stamp
    var desired: [String: (BackupFeedsFile.Feed, BackupFeedsFile)] = [:]
    if let data = FileManager.default.contents(atPath: feedsPath),
       let cfg = try? JSONDecoder().decode(BackupFeedsFile.self, from: data) {
        for f in cfg.feeds { desired[key(f, cfg)] = (f, cfg) }
    }
    for (k, w) in workers where desired[k] == nil { w.cancel(); workers[k] = nil }
    for (k, v) in desired where workers[k] == nil {
        let w = Worker(feed: v.0, host: v.1.host, port: v.1.port, password: v.1.password)
        workers[k] = w
        w.start()
        print("feeder: streaming \(v.0.file) to \(v.0.mount)")
    }
}

func writeStatus() {
    let status = BackupFeederStatus(updated: Date().timeIntervalSince1970, pid: getpid(),
                                    feeds: workers.values.map(\.snapshot).sorted { $0.mount < $1.mount })
    if let data = try? JSONEncoder().encode(status) { try? data.write(to: URL(fileURLWithPath: statusPath), options: .atomic) }
}

print("feeder: started (pid \(getpid()))")
while true {
    reloadFeeds()
    writeStatus()
    Thread.sleep(forTimeInterval: 1)
}
