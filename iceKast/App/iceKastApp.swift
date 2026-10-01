import SwiftUI

@main
struct iceKastApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("iceKast") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
