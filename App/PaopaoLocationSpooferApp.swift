import SwiftUI

@main
struct PaopaoLocationSpooferApp: App {
    init() {
        RuntimeLogger.info("APP", "Lifecycle", "========== App 启动 ==========")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, AppLocalization.locale)
        }
    }
}
