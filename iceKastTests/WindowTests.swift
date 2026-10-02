import XCTest
import SwiftUI
@testable import iceKast

/// Renders the main window offscreen and checks that no page is blank.
/// NOTE: this does NOT catch layout problems that only appear in a window that is actually on
/// screen (one such bug blanked the whole window and this test still passed). For that, run
/// scripts/smoke-window.sh, which launches the real app and inspects its real window.
@MainActor
final class MainWindowTests: XCTestCase {
    /// Fraction of pixels in `rect` that differ noticeably from the region's dominant colour.
    private func ink(_ rep: NSBitmapImageRep, in rect: CGRect) -> Double {
        var counts: [UInt32: Int] = [:]
        var samples: [UInt32] = []
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let v = (UInt32(c.redComponent * 255) << 16) | (UInt32(c.greenComponent * 255) << 8) | UInt32(c.blueComponent * 255)
                counts[v, default: 0] += 1; samples.append(v)
            }
        }
        guard let dominant = counts.max(by: { $0.value < $1.value })?.key, !samples.isEmpty else { return 0 }
        func dist(_ a: UInt32, _ b: UInt32) -> Int {
            abs(Int((a >> 16) & 255) - Int((b >> 16) & 255)) + abs(Int((a >> 8) & 255) - Int((b >> 8) & 255)) + abs(Int(a & 255) - Int(b & 255))
        }
        return Double(samples.filter { dist($0, dominant) > 40 }.count) / Double(samples.count)
    }

    private func render(selection: SidebarSelection, tab: MountTab) throws -> NSBitmapImageRep {
        let model = AppModel()
        model.mountTab = tab
        let host = NSHostingView(rootView: ContentView(initialSelection: selection).environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 880, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    func testServerPageAndMountPageBothRenderInTheMainWindow() throws {
        let model = AppModel()
        let mountID = try XCTUnwrap(model.config.mounts.first?.id)
        for (name, sel, tab) in [("server", SidebarSelection.server, MountTab.connect),
                                 ("mount/connect", .mount(mountID), .connect),
                                 ("mount/share", .mount(mountID), .share),
                                 ("mount/stream info", .mount(mountID), .streamInfo),
                                 ("mount/backup", .mount(mountID), .backup),
                                 ("mount/advanced", .mount(mountID), .advanced)] {
            let rep = try render(selection: sel, tab: tab)
            let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
            // sidebar column (left ~25%) and the detail pane (the rest), below the title bar
            let sidebar = ink(rep, in: CGRect(x: 0, y: 70, width: w * 0.22, height: h * 0.4))
            let detail = ink(rep, in: CGRect(x: w * 0.30, y: 70, width: w * 0.65, height: h * 0.6))
            XCTAssertGreaterThan(sidebar, 0.002, "\(name): the sidebar is blank")
            XCTAssertGreaterThan(detail, 0.02, "\(name): the page is blank")
        }
    }
}
