import Foundation

enum AlertEvent: Equatable {
    case encoderConnected(mount: String)
    case encoderDropped(mount: String)
    case serverNotResponding
    case serverRecovered
    case listenerLimitReached(mount: String?, listeners: Int, limit: Int)   // nil mount = whole server

    enum Category { case encoder, serverProblem, listenerLimit }

    var category: Category {
        switch self {
        case .encoderConnected, .encoderDropped: .encoder
        case .serverNotResponding, .serverRecovered: .serverProblem
        case .listenerLimitReached: .listenerLimit
        }
    }

    var title: String {
        switch self {
        case .encoderConnected(let m): "Encoder connected — \(m)"
        case .encoderDropped(let m): "Encoder dropped off — \(m)"
        case .serverNotResponding: "Your server isn't responding"
        case .serverRecovered: "Your server is back"
        case .listenerLimitReached: "Listener limit reached"
        }
    }

    var message: String {
        switch self {
        case .encoderConnected(let m):
            "\(m) is on the air."
        case .encoderDropped(let m):
            "No audio is reaching \(m). Listeners hear silence unless you've set backup audio."
        case .serverNotResponding:
            "Your station may be off the air. Open LogiKast to see why."
        case .serverRecovered:
            "The server is responding again."
        case .listenerLimitReached(let m, let n, let limit):
            "\(m ?? "The server") has \(n) of \(limit) listeners. New listeners are being turned away."
        }
    }

    /// Alerts that mean something is wrong play a sound.
    var isUrgent: Bool {
        switch self {
        case .encoderDropped, .serverNotResponding: true
        default: false
        }
    }
}

/// Turns a stream of server snapshots into alert events. Pure logic: time is passed in.
/// - The first snapshot after the server becomes reachable only seeds what is already live,
///   so reopening LogiKast never announces streams that were on the air all along.
/// - Drops and outages must last `grace` seconds, so a quick reconnect or hot reload is quiet.
struct AlertTracker {
    var encoderGrace: TimeInterval = 4
    var serverGrace: TimeInterval = 10

    private var seeded = false
    private var live = Set<String>()
    private var missingSince: [String: Date] = [:]
    private var serverWasUp = false
    private var downSince: Date?
    private var serverAlerted = false
    private var limitAlerted = Set<String>()        // "" = server-wide

    mutating func reset() { self = AlertTracker(encoderGrace: encoderGrace, serverGrace: serverGrace) }

    /// - status: nil means the server did not answer.
    /// - mountLimits: per-mount listener caps (0 = none). serverLimit: server-wide cap.
    mutating func update(now: Date, enabled: Bool, status: ServerStatus?,
                         serverLimit: Int, mountLimits: [String: Int]) -> [AlertEvent] {
        guard enabled else { reset(); return [] }
        var events: [AlertEvent] = []

        guard let status else {
            // Not answering. Everything that was live is gone with it.
            if serverWasUp {
                downSince = downSince ?? now
                if !serverAlerted, now.timeIntervalSince(downSince!) >= serverGrace {
                    serverAlerted = true
                    events.append(.serverNotResponding)
                    live.removeAll(); missingSince.removeAll(); limitAlerted.removeAll()
                    seeded = false
                }
            }
            return events
        }

        // Answering again.
        downSince = nil
        if serverAlerted {
            serverAlerted = false
            events.append(.serverRecovered)
        }
        serverWasUp = true

        let nowLive = Set(status.mounts.map(\.path))
        if !seeded {
            live = nowLive
            seeded = true
            missingSince.removeAll()
        } else {
            for m in nowLive.subtracting(live).sorted() {
                live.insert(m); missingSince[m] = nil
                events.append(.encoderConnected(mount: m))
            }
            for m in live.subtracting(nowLive).sorted() {
                let since = missingSince[m] ?? now
                missingSince[m] = since
                if now.timeIntervalSince(since) >= encoderGrace {
                    live.remove(m); missingSince[m] = nil
                    events.append(.encoderDropped(mount: m))
                }
            }
            for m in nowLive { missingSince[m] = nil }   // back before the grace ran out: quiet
        }

        // Listener limits, with hysteresis so a count hovering at the cap alerts once.
        func check(_ key: String, mount: String?, count: Int, limit: Int) {
            guard limit > 0 else { return }
            if count >= limit {
                if limitAlerted.insert(key).inserted {
                    events.append(.listenerLimitReached(mount: mount, listeners: count, limit: limit))
                }
            } else if Double(count) < Double(limit) * 0.9 {
                limitAlerted.remove(key)
            }
        }
        check("", mount: nil, count: status.totalListeners, limit: serverLimit)
        for m in status.mounts { check(m.path, mount: m.path, count: m.listeners, limit: mountLimits[m.path] ?? 0) }
        return events
    }
}
