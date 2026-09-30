#if os(macOS)
import SpektrafilmCore
import SwiftUI

@main
struct SpektrafilmSwiftUIApp: App {
    init() {
        AppLog.configureFromEnvironment()
        AppLog.info("app", "Spektrafilm SwiftUI starting")
    }
    @StateObject private var model = AppViewModel()
    @AppStorage(AdjustmentInterfacePreferences.appearanceKey)
    private var appearanceRaw = AppAppearance.system.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup("") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.profiles)
                .environmentObject(model.imageService)
                .environmentObject(model.renderService)
                .environmentObject(model.previews)
                .environmentObject(model.viewport)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 1200, height: 800)
        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
#else
import Foundation
import SpektrafilmCore
@main struct UnsupportedPlatform {
    static func main() { AppLog.warning("app", "SpektrafilmApp requires macOS (SwiftUI target); SpektrafilmCore is cross-platform.") }
}
#endif
