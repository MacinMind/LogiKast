import AppKit

/// Draws the listener count on the Dock icon itself. NSDockTile.badgeLabel is silently ignored when macOS
/// notification settings don't allow a badge for the app, so iceKast draws its own, which always works.
@MainActor
enum DockBadge {
    private final class TileView: NSView {
        var label = ""
        var icon: NSImage?

        override func draw(_ dirtyRect: NSRect) {
            icon?.draw(in: bounds)
            DockBadge.drawBadge(label, in: bounds)
        }
    }

    private static var view: TileView?

    /// Shows `label` on the Dock icon, or the plain icon when nil.
    static func set(_ label: String?) {
        guard let tile = NSApp?.dockTile else { return }
        guard let label, !label.isEmpty else {
            if view != nil { tile.contentView = nil; view = nil; tile.display() }
            return
        }
        let v = view ?? TileView(frame: NSRect(origin: .zero, size: tile.size))
        v.frame = NSRect(origin: .zero, size: tile.size)
        if view == nil { v.icon = NSApp.applicationIconImage; tile.contentView = v; view = v }
        guard v.label != label else { return }
        v.label = label
        tile.display()
    }

    /// A red circle (a pill for long numbers) with white digits in the icon's upper right corner.
    static func drawBadge(_ label: String, in bounds: NSRect) {
        let height = bounds.height * 0.34
        let font = NSFont.systemFont(ofSize: height * 0.62, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: label, attributes: attrs)
        let textSize = text.size()
        let width = max(height, textSize.width + height * 0.5)
        let rect = NSRect(x: bounds.maxX - width - bounds.width * 0.02, y: bounds.maxY - height - bounds.height * 0.02, width: width, height: height)
        NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2, yRadius: height / 2)
        ring.lineWidth = 1
        ring.stroke()
        text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
    }
}
