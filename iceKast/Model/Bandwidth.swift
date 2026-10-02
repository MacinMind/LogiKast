import Foundation

/// Running byte counts for one mount, from Icecast's admin statistics.
struct ByteCounters: Equatable {
    var sent: UInt64      // to listeners
    var read: UInt64      // from the encoder
}

/// Bits per second, going out to listeners and coming in from encoders.
struct BandwidthRates: Equatable {
    /// Per mount path (internal backup mounts included under their own path).
    var out: [String: Double] = [:]
    var into: [String: Double] = [:]
    var totalOut: Double { out.values.reduce(0, +) }
    var totalIn: Double { into.values.reduce(0, +) }

    /// Outgoing rate of a mount, including listeners who are hearing its backup audio.
    func outgoing(mount: String) -> Double? {
        guard let live = out[mount] else { return nil }
        return live + (out[BackupAudio.internalMount(forMount: mount)] ?? 0)
    }

    static func format(_ bitsPerSecond: Double) -> (value: String, unit: String) {
        let kbps = bitsPerSecond / 1000
        if kbps < 1 { return ("0", "kb/s") }
        if kbps < 1000 { return (String(Int(kbps.rounded())), "kb/s") }
        let mbps = kbps / 1000
        return (String(format: mbps < 10 ? "%.2f" : "%.1f", mbps), "Mb/s")
    }
}

/// Turns counter readings into rates over a short sliding window. Encoders send in bursts, so a single 2-second
/// difference jumps around; averaging over about 8 seconds gives a steady figure. One subtraction per mount per reading.
struct BandwidthMeter {
    var window: TimeInterval = 8
    private var samples: [(time: Date, counters: [String: ByteCounters])] = []

    /// nil until there are two readings at least a moment apart.
    mutating func update(_ counters: [String: ByteCounters], at now: Date) -> BandwidthRates? {
        samples.append((now, counters))
        samples.removeAll { now.timeIntervalSince($0.time) > window + 1 }
        // Compare with the oldest reading still inside the window.
        guard let base = samples.first(where: { now.timeIntervalSince($0.time) <= window + 0.5 }),
              now.timeIntervalSince(base.time) > 0.2 else { return nil }
        let dt = now.timeIntervalSince(base.time)
        var rates = BandwidthRates()
        for (mount, c) in counters {
            // A counter that went down means the mount restarted: skip it until it has history again.
            guard let p = base.counters[mount], c.sent >= p.sent, c.read >= p.read else { continue }
            rates.out[mount] = Double(c.sent - p.sent) * 8 / dt
            rates.into[mount] = Double(c.read - p.read) * 8 / dt
        }
        return rates
    }

    mutating func reset() { samples = [] }
}
