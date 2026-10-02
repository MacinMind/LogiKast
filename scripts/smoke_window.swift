// Launches the real iceKast app, captures its real window, and fails if it is blank.
// Offscreen tests can't see layout bugs that only show in a displayed window.
// Usage: swift scripts/smoke_window.swift /path/to/iceKast.app
import AppKit
import CoreGraphics
import Foundation

let appPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard FileManager.default.fileExists(atPath: appPath) else { print("usage: smoke_window.swift <iceKast.app>"); exit(2) }

func run(_ exe: String, _ args: [String]) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}
func windowID() -> Int? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.first { ($0[kCGWindowOwnerName as String] as? String) == "iceKast" && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int
}
/// Fraction of pixels in the region that differ clearly from its dominant colour.
func ink(_ rep: NSBitmapImageRep, _ r: CGRect) -> Double {
    var counts: [UInt32: Int] = [:], px: [UInt32] = []
    for y in stride(from: Int(r.minY), to: min(Int(r.maxY), rep.pixelsHigh), by: 2) {
        for x in stride(from: Int(r.minX), to: min(Int(r.maxX), rep.pixelsWide), by: 2) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let v = (UInt32(c.redComponent * 255) << 16) | (UInt32(c.greenComponent * 255) << 8) | UInt32(c.blueComponent * 255)
            counts[v, default: 0] += 1; px.append(v)
        }
    }
    guard let dom = counts.max(by: { $0.value < $1.value })?.key, !px.isEmpty else { return 0 }
    func d(_ a: UInt32, _ b: UInt32) -> Int {
        abs(Int((a >> 16) & 255) - Int((b >> 16) & 255)) + abs(Int((a >> 8) & 255) - Int((b >> 8) & 255)) + abs(Int(a & 255) - Int(b & 255))
    }
    return Double(px.filter { d($0, dom) > 40 }.count) / Double(px.count)
}

/// True if a scroll bar thumb is visible along the window's right edge (a long dark vertical run).
/// macOS flashes the scroll bars when a window first appears, so content that overflows shows one.
func scrollBarVisible(_ rep: NSBitmapImageRep) -> Bool {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var run = 0, best = 0
    for y in 70..<(h - 4) {
        var dark = 0
        for x in (w - 16)..<(w - 2) {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent < 0.80 { dark += 1 }
        }
        if dark >= 3 { run += 1; best = max(best, run) } else { run = 0 }
    }
    return best >= 30
}

/// `scrolls`: pages that are expected to need a scroll bar at the minimum window size.
struct Case { let name: String; let args: [String]; var scrolls = false }
var cases = [Case(name: "server / network", args: ["--server-tab", "network"]),
             Case(name: "server / access", args: ["--server-tab", "access"]),
             Case(name: "server / alerts", args: ["--server-tab", "alerts"]),
             Case(name: "server / app", args: ["--server-tab", "app"])]
for t in ["connect", "share", "streamInfo", "backup", "advanced"] {
    cases.append(Case(name: "mount / \(t)", args: ["--show-mount", "--mount-tab", t], scrolls: t == "share"))
}

var failures = 0
for c in cases {
    // The window can take a while to appear (it varies run to run), so poll for it; relaunch if it never does.
    var found: Int?
    for _ in 1...2 {
        run("/usr/bin/pkill", ["-x", "iceKast"]); Thread.sleep(forTimeInterval: 1.5)
        run("/usr/bin/open", ["-g", "-n", appPath, "--args"] + c.args)   // -g: do not take focus (your typing must never land in iceKast)
        let deadline = Date().addingTimeInterval(20)
        while found == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.5); found = windowID() }
        if found != nil { break }
    }
    if found != nil {
        Thread.sleep(forTimeInterval: 3)                       // let the page finish laying out (no activation: never steal focus)
        found = windowID() ?? found
    }
    guard let id = found else { print("FAIL  \(c.name): no window after 2 launches (40 s)"); failures += 1; continue }
    let out = NSTemporaryDirectory() + "smoke-\(id).png"
    run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), out])
    guard let data = FileManager.default.contents(atPath: out), let rep = NSBitmapImageRep(data: data) else { print("FAIL  \(c.name): no capture"); failures += 1; continue }
    let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
    let sidebar = ink(rep, CGRect(x: 0, y: 70, width: w * 0.22, height: h * 0.4))
    let detail = ink(rep, CGRect(x: w * 0.30, y: 70, width: w * 0.65, height: h * 0.6))
    let bar = scrollBarVisible(rep)
    let ok = sidebar > 0.002 && detail > 0.02 && bar == c.scrolls
    let barNote = bar ? "SCROLL BAR" : "no scroll bar"
    print("\(ok ? "ok  " : "FAIL")  \(c.name): sidebar ink \(String(format: "%.3f", sidebar)), page ink \(String(format: "%.3f", detail)), \(barNote)\(bar != c.scrolls ? (c.scrolls ? " (expected one)" : " (not expected)") : "")")
    if !ok { failures += 1 }
    try? FileManager.default.removeItem(atPath: out)
}
run("/usr/bin/pkill", ["-x", "iceKast"])
print(failures == 0 ? "smoke test PASSED" : "smoke test FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
