import Foundation
import ServiceManagement

/// Opens iceKast (in the menu bar) when you log in, so alerts keep working.
/// The server itself starts at login on its own; this is only for the app.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var lastError: String?

    private var service: SMAppService { SMAppService.mainApp }

    init() { refresh() }

    func refresh() {
        isEnabled = service.status == .enabled
        needsApproval = service.status == .requiresApproval
    }

    func set(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
