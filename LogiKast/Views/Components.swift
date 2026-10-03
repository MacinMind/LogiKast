import SwiftUI
import AppKit

struct CopyableRow: View {
    let label: String
    let value: String
    var secret = false
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(secret && !revealed ? String(repeating: "•", count: max(value.count, 6)) : value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            if secret {
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help(revealed ? "Hide" : "Show")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
            .buttonStyle(.borderless).help("Copy")
        }
    }
}

struct IntField: View {
    let title: String
    @Binding var value: Int
    var suffix: String?

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField("", value: $value, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                if let suffix { Text(suffix).foregroundStyle(.secondary) }
            }
        }
    }
}

struct IssuesView: View {
    let issues: [ConfigIssue]
    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues) { i in
                    Label(i.message, systemImage: i.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(i.severity == .error ? Color.red : Color.orange)
                        .font(.callout)
                }
            }
        }
    }
}

/// Description editor: wraps over a few lines like a text area, but never accepts line breaks.
struct DescriptionField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Description")
            TextField("", text: $text, prompt: Text(prompt), axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                if text.count > StreamInfoText.softLimit {
                    Text("Shorter descriptions work best in directories.")
                }
                Spacer()
                Text("\(text.count)/\(StreamInfoText.softLimit)").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(text.count > StreamInfoText.softLimit ? Color.orange : Color.secondary)
        }
        .onChange(of: text) { new in
            let cleaned = StreamInfoText.clean(new)
            if cleaned != new { text = cleaned }
        }
    }
}

/// Text with [links](https://…) rendered, as a native text view so that a link shows the pointing-hand cursor and is
/// underlined while the pointer is on it. (SwiftUI's own `Text` renders links but has no hover or cursor control on macOS.)
/// Pass the complete markdown string.
struct LinkedText: View {
    let markdown: String
    var font: NSFont = .systemFont(ofSize: 13)
    var color: NSColor = .labelColor

    var body: some View {
        // Takes the full width it is offered (a stack would otherwise size it to a few characters) and wraps within it.
        LinkedTextView(markdown: markdown, font: font, color: color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LinkedTextView: NSViewRepresentable {
    let markdown: String
    let font: NSFont
    let color: NSColor

    func makeNSView(context: Context) -> HoverLinkTextView {
        let view = HoverLinkTextView()
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = true            // links only react to clicks when the view is selectable
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        return view
    }

    func updateNSView(_ view: HoverLinkTextView, context: Context) {
        let text = NSMutableAttributedString()
        if let parsed = try? AttributedString(markdown: markdown) { text.append(NSAttributedString(parsed)) } else { text.append(NSAttributedString(string: markdown)) }
        let all = NSRange(location: 0, length: text.length)
        text.addAttributes([.font: font, .foregroundColor: color], range: all)
        view.textStorage?.setAttributedString(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: HoverLinkTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        // A finite width is a real column to wrap in. An unspecified or infinite one (stacks and form footers ask this way)
        // means "how wide would you like to be": measure the text on one line and report that.
        let offered = proposal.width.flatMap { $0.isFinite ? max($0, 20) : nil }
        // Measuring must not leave the container at the measured width: the view wraps at its own frame width.
        let previous = container.containerSize
        defer { container.containerSize = previous }
        container.containerSize = NSSize(width: offered ?? 100_000, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: min(offered ?? .infinity, ceil(used.width)), height: ceil(used.height))
    }
}

/// A text view that underlines the link under the pointer.
final class HoverLinkTextView: NSTextView {
    private var underlined: NSRange?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setUnderline(linkRange(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setUnderline(nil)
    }

    /// The range of the link under `point`, or nil when the pointer is on ordinary text or empty space.
    private func linkRange(at point: NSPoint) -> NSRange? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(p) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        var range = NSRange(location: 0, length: 0)
        guard storage.attribute(.link, at: index, effectiveRange: &range) != nil else { return nil }
        return range
    }

    private func setUnderline(_ range: NSRange?) {
        guard range != underlined, let layout = layoutManager else { return }
        if let old = underlined { layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: old) }
        if let range { layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: range) }
        underlined = range
    }
}

/// Explanatory text under a form section. Spelled out as left-aligned because before macOS 26 a footer that wraps is centered.
struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
