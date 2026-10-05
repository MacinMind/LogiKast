import AppKit

/// The About window: the standard one, plus credits for Icecast and the other bundled software.
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
        NSApp.activate(ignoringOtherApps: true)
    }

    static func credits() -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
        let out = NSMutableAttributedString()
        func add(_ text: String, link: String? = nil) {
            var a = base
            if let link, let url = URL(string: link) { a[.link] = url }
            out.append(NSAttributedString(string: text, attributes: a))
        }
        add("Source: ")
        add("github.com/MacinMind/LogiKast", link: "https://github.com/MacinMind/LogiKast")
        add("\nRuns ")
        add("Icecast", link: "https://icecast.org")
        add(" from the Xiph.Org Foundation, under the GPL version 2.\nAlso includes libxml2, libxslt, libogg, libvorbis, libigloo, curl and RHash. ")
        if let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
            add("View licenses and notices", link: notices.absoluteString)
        }
        return out
    }
}
