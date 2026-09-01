import Foundation

/// 环境验证结果，由 SetupCoordinator 统一路由到对应引导页面。
enum VerificationResult: Equatable, Identifiable {
    case success
    case proxyNotRunning
    case verificationInProgress
    case verificationSuperseded
    case certNotTrusted
    case wifiProxyNotConfigured
    case builtInVPNNotActive
    case coordinateWriteFailed(String)
    case patchFailed(String)

    var id: String {
        switch self {
        case .success: return "成功"
        case .proxyNotRunning: return "代理未运行"
        case .verificationInProgress: return "已有验证正在进行"
        case .verificationSuperseded: return "验证已被新位置取代"
        case .certNotTrusted: return "证书未信任"
        case .wifiProxyNotConfigured: return "WiFi代理未配置"
        case .builtInVPNNotActive: return "内置VPN未生效"
        case .coordinateWriteFailed: return "坐标写入失败"
        case .patchFailed: return "改写验证失败"
        }
    }

    var isSuccess: Bool { self == .success }

}
