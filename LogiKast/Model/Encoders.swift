import Foundation

/// Encoder apps we point people to, in the order they should always be listed.
struct EncoderApp: Identifiable {
    let name: String
    let url: URL
    /// Whether the app sends a stream description (Name, Genre and Website are sent by all of them).
    let sendsDescription: Bool
    var id: String { name }
}

enum Encoders {
    static let all: [EncoderApp] = [
        EncoderApp(name: "Audio Hijack", url: URL(string: "https://rogueamoeba.com/audiohijack/")!, sendsDescription: false),
        EncoderApp(name: "LadioCast", url: URL(string: "https://apps.apple.com/us/app/ladiocast/id411213048")!, sendsDescription: true),
        EncoderApp(name: "BUTT", url: URL(string: "https://danielnoethen.de/butt/")!, sendsDescription: true),
        EncoderApp(name: "BUTTM", url: URL(string: "https://buttm.app")!, sendsDescription: true),
    ]

    private static func link(_ e: EncoderApp) -> String { "[\(e.name)](\(e.url.absoluteString))" }

    /// "Audio Hijack, LadioCast, BUTT and BUTTM" as markdown links, for SwiftUI `Text`.
    static var linkedList: String {
        let links = all.map(link)
        return links.dropLast().joined(separator: ", ") + " and " + links.last!
    }

    /// Shown wherever stream info is entered: blank fields are filled in by the encoder.
    static var streamInfoNote: String {
        let noDesc = all.filter { !$0.sendsDescription }.map(link).joined(separator: " and ")
        let allFour = all.filter { $0.sendsDescription }.map(link)
        let allFourText = allFour.dropLast().joined(separator: ", ") + " and " + allFour.last!
        return "Anything you leave blank is filled in by your encoder, if it sends it. \(noDesc) sends the name, genre and website but not a description; \(allFourText) send all four."
    }
}
