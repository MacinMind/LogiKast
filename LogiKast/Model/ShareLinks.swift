import Foundation
import AppKit
import CoreImage

/// Links and snippets for sharing a mount with listeners.
struct ShareLinks {
    var host: String
    var port: Int
    var mount: String
    var title: String

    /// IPv6 literals need brackets in a URL.
    private var urlHost: String {
        let h = host.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : host.trimmingCharacters(in: .whitespaces)
        return h.contains(":") && !h.hasPrefix("[") ? "[\(h)]" : h
    }

    var listenURL: String { "http://\(urlHost):\(port)\(mount)" }
    /// Icecast serves a playlist at <mount>.m3u that desktop players (Music, VLC…) open directly.
    var playlistURL: String { listenURL + ".m3u" }

    /// An HTML5 audio player for a web page.
    var playerHTML: String {
        let label = Self.escapeHTML(title.isEmpty ? "Live stream" : title)
        return """
        <audio controls preload="none" aria-label="\(label)" src="\(listenURL)">
          <a href="\(listenURL)">Listen live</a>
        </audio>
        """
    }

    /// Browsers refuse to play http audio on an https page, so the player only works on http:// pages.
    static let httpsNote = "The website player code works only on http:// pages: browsers block http:// audio on https:// sites, so link to the stream there instead."

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum QRCode {
    /// A crisp QR code for `text`, `size` points square (nearest-neighbor scaling, with quiet zone).
    static func image(for text: String, size: CGFloat = 220) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let raw = filter.outputImage else { return nil }
        let quiet: CGFloat = 4
        let modules = raw.extent.width + quiet * 2
        let scale = max(1, floor(size / modules))
        let padded = raw.transformed(by: CGAffineTransform(translationX: quiet, y: quiet))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: modules, height: modules)))
        let scaled = padded.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    static func pngData(for text: String, size: CGFloat = 1024) -> Data? {
        guard let image = image(for: text, size: size),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
