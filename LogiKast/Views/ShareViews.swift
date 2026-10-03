import SwiftUI
import AppKit

/// Website player code with a Copy button.
struct SharePlayerView: View {
    let share: ShareLinks
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Website player").foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(share.playerHTML, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Player Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }
            Text(share.playerHTML)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// QR code for the listen link, with Save as PNG.
struct QRShareView: View {
    let url: String
    let mountName: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let image = QRCode.image(for: url, size: 110) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 110, height: 110)
                    .accessibilityLabel("QR code for \(url)")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("QR code").foregroundStyle(.secondary)
                Text("Scan with a phone camera to open the stream. Handy for posters, flyers and social media.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Save QR Code…", action: save)
            }
            Spacer()
        }
    }

    private func save() {
        guard let png = QRCode.pngData(for: url) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "LogiKast\(mountName.replacingOccurrences(of: "/", with: "-")) QR.png"
        if panel.runModal() == .OK, let dest = panel.url {
            try? png.write(to: dest)
        }
    }
}
