import Foundation
import UIKit

enum SystemSettingsDestination {
    case appPermissions
    case general
    case wifi
    case locationServices

    var preferredURL: URL? {
        let value: String
        switch self {
        case .appPermissions:
            value = UIApplication.openSettingsURLString
        case .general:
            value = "App-Prefs:General"
        case .wifi:
            value = "App-Prefs:WIFI"
        case .locationServices:
            value = "App-Prefs:Privacy&path=LOCATION"
        }
        return URL(string: value)
    }

    var manualPath: String {
        switch self {
        case .appPermissions:
            return AppLocalization.string("请手动打开「设置」，找到本 App 后检查定位权限。")
        case .general:
            return AppLocalization.string("请手动打开「设置 → 通用」。")
        case .wifi:
            return AppLocalization.string("请手动打开「设置 → 无线局域网」，进入当前 Wi-Fi 的详情页。")
        case .locationServices:
            return AppLocalization.string("请手动打开「设置 → 隐私与安全性 → 定位服务」。")
        }
    }
}

@MainActor
enum SystemSettingsNavigator {
    static func open(
        _ destination: SystemSettingsDestination,
        completion: @escaping @MainActor @Sendable (String?) -> Void = { _ in }
    ) {
        let appSettingsURL = URL(string: UIApplication.openSettingsURLString)
        let preferredURL = destination.preferredURL

        openURL(preferredURL) { openedPreferred in
            guard !openedPreferred else {
                completion(nil)
                return
            }
            guard preferredURL != appSettingsURL else {
                completion(destination.manualPath)
                return
            }
            openURL(appSettingsURL) { openedFallback in
                completion(openedFallback ? nil : destination.manualPath)
            }
        }
    }

    private static func openURL(_ url: URL?, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let url else {
            completion(false)
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            completion(opened)
        }
    }
}
