import Foundation

/// What the app asks the background feeder to stream (written by iceKast, read by icekast-feeder).
struct BackupFeedsFile: Codable, Equatable {
    struct Feed: Codable, Equatable {
        var mount: String           // internal mount the audio is sent to, e.g. /_backup/live
        var file: String            // absolute path of the backup audio file
        var contentType: String     // audio/mpeg or audio/aac
        var name: String            // shown in logs / Icecast stats
    }
    var host: String
    var port: Int
    var password: String
    var feeds: [Feed]
}

/// What the feeder reports back (written by icekast-feeder every second, read by iceKast).
struct BackupFeederStatus: Codable, Equatable {
    struct FeedState: Codable, Equatable {
        var mount: String
        var state: String           // "streaming", "connecting" or "error"
        var detail: String
    }
    var updated: Double             // seconds since 1970
    var pid: Int32
    var feeds: [FeedState]

    /// True while the feeder is alive (it refreshes this file every second).
    func isFresh(now: Date = Date(), within seconds: TimeInterval = 6) -> Bool {
        now.timeIntervalSince1970 - updated <= seconds
    }
}
