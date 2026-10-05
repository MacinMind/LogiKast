import SwiftUI

protocol TabItem: Hashable, CaseIterable, Identifiable {
    var title: String { get }
}
extension TabItem { var id: Self { self } }

/// Modern segmented tab bar shown above a page's settings form.
struct SegmentedTabs<T: TabItem>: View where T.AllCases: RandomAccessCollection {
    @Binding var selection: T

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(T.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 560)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
    }
}

enum MountTab: String, TabItem {
    case connect, streamInfo, share, listeners, backup, advanced
    var title: String {
        switch self {
        case .connect: "Connect"
        case .streamInfo: "Stream Info"
        case .share: "Share"
        case .listeners: "Listeners"
        case .backup: "Backup"
        case .advanced: "Advanced"
        }
    }
}

enum ServerTab: String, TabItem {
    case setup, limits, relay, alerts, app, updates
    var title: String {
        switch self {
        case .setup: "Setup"
        case .limits: "Limits"
        case .relay: "Relay"
        case .alerts: "Alerts"
        case .app: "App & Log"
        case .updates: "Updates"
        }
    }
}

/// Rounded card used for the status area pinned above the tabs.
struct StatusPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
            .padding(.horizontal, 20)
            .padding(.top, 14)
    }
}
