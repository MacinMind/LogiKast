import Foundation
import Combine
import Sparkle

/// Where updates come from. Final releases and beta releases have separate appcasts.
enum UpdateFeed {
    static let finalURL = "https://macinmind.com/pads/LogiKast.xml"
    static let betaURL = "https://macinmind.com/pads/LogiKastbeta.xml"

    static func url(includeBetas: Bool) -> String { includeBetas ? betaURL : finalURL }

    /// "1.0b3" is a beta, "1.0" is a final release.
    static func isBeta(version: String) -> Bool {
        version.range(of: #"^\d+(\.\d+)*b\d+$"#, options: .regularExpression) != nil
    }
}

/// Software updates through Sparkle: a "Check for Updates…" command, automatic checks, and a switch for beta releases.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let betaKey = "includeBetaVersions"

    @Published var includeBetas: Bool {
        didSet { UserDefaults.standard.set(includeBetas, forKey: Self.betaKey) }
    }
    @Published var automaticChecks: Bool {
        didSet { if oldValue != automaticChecks { controller?.updater.automaticallyChecksForUpdates = automaticChecks } }
    }
    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?

    private var controller: SPUStandardUpdaterController?
    private var observers = Set<AnyCancellable>()

    override init() {
        let shortVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        // People running a beta get betas by default; everyone else gets final releases until they choose otherwise.
        includeBetas = (UserDefaults.standard.object(forKey: Self.betaKey) as? Bool) ?? UpdateFeed.isBeta(version: shortVersion)
        automaticChecks = true
        super.init()
        UserDefaults.standard.set(includeBetas, forKey: Self.betaKey)      // the feed callback reads this directly
        // Unit tests run inside the app and must not talk to the network or show update windows.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        automaticChecks = c.updater.automaticallyChecksForUpdates
        lastCheck = c.updater.lastUpdateCheckDate
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &observers)
        c.updater.publisher(for: \.lastUpdateCheckDate).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastCheck = $0 }.store(in: &observers)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "LogiKastFeedOverride"), !override.isEmpty { return override }   // local testing only
        #endif
        return UpdateFeed.url(includeBetas: UserDefaults.standard.bool(forKey: Self.betaKey))
    }
}
