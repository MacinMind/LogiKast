import SwiftUI
import WebKit

/// Help › Version Notes: the release notes from the update feed, in a small window.
struct VersionNotesView: View {
    @ObservedObject var updater: Updater
    @State private var page: String?
    @State private var message: String? = "Loading…"

    var body: some View {
        Group {
            if let page {
                NotesWebView(html: page)
            } else {
                VStack(spacing: 10) {
                    Text(message ?? "").foregroundStyle(.secondary)
                    if message != "Loading…" { Button("Try Again") { Task { await load() } } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .navigationTitle(VersionNotes.menuTitle(includeBetas: updater.includeBetas))
        .task(id: updater.includeBetas) { await load() }
    }

    private func load() async {
        page = nil; message = "Loading…"
        do {
            let notes = try await VersionNotes.fetch(includeBetas: updater.includeBetas)
            if notes.isEmpty { message = "There are no version notes yet." } else { page = VersionNotes.page(for: notes) }
        } catch {
            message = "Couldn't load the version notes. Check your internet connection."
        }
    }
}

private struct NotesWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) { view.loadHTMLString(html, baseURL: nil) }
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Links in the notes open in the browser, never inside this window.
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
