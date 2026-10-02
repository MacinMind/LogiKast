import Foundation
import UserNotifications
import AppKit
import os

/// Sends macOS notifications for AlertEvents. Asks for permission the first time one is needed.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum Permission { case unknown, notAsked, allowed, denied }

    @Published private(set) var permission = Permission.unknown
    private let log = Logger(subsystem: "com.macinmind.icekast", category: "alerts")
    private var center: UNUserNotificationCenter? {
        // Unit tests run inside the app without a real notification context.
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? UNUserNotificationCenter.current() : nil
    }

    override init() {
        super.init()
        center?.delegate = self
        refreshPermission()
    }

    func refreshPermission() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] s in
            let p: Permission
            switch s.authorizationStatus {
            case .notDetermined: p = .notAsked
            case .denied: p = .denied
            default: p = .allowed
            }
            Task { @MainActor in self?.permission = p }
        }
    }

    func post(_ event: AlertEvent) {
        log.notice("alert: \(event.title, privacy: .public)")
        send(title: event.title, body: event.message, urgent: event.isUrgent)
    }

    func sendTest() {
        send(title: "iceKast notifications are on", body: "You'll see alerts like this when your encoder drops off or your server stops responding.", urgent: false)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func send(title: String, body: String, urgent: Bool) {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.refreshPermission() }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if urgent { content.sound = .default }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // Show banners even while iceKast is the front app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
