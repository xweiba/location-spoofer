import Foundation

/// Chooses the app language from the first preferred language only. iOS normally
/// scans the whole preference list, which can select Chinese when Italian is first
/// and Chinese is second; this app intentionally falls back to English instead.
enum AppLocalization {
    static func identifier(for preferredLanguages: [String]) -> String {
        guard let first = preferredLanguages.first,
              Locale(identifier: first).languageCode == "zh" else {
            return "en"
        }
        return Bundle.preferredLocalizations(
            from: ["zh-Hans", "zh-Hant"], forPreferences: [first]
        ).first ?? "zh-Hans"
    }

    static let identifier = identifier(for: Locale.preferredLanguages)
    static let locale = Locale(identifier: identifier)

    // An explicit .lproj bundle also covers String(localized:) calls made outside
    // SwiftUI views, where the view's locale environment is not available.
    private static let localizedBundle: Bundle = {
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }()

    static func string(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: localizedBundle)
    }
}
