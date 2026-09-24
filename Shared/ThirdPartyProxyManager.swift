import Foundation

struct ThirdPartyProxySettingsResponse: Decodable, Equatable {
    let success: Bool
    let longitude: Double?
    let latitude: Double?
    let accuracy: Int?
    let error: String?
    let motionSimulationEnabled: Bool?
}

enum ThirdPartyProxyConnectionState: Equatable {
    case unknown
    case connected(active: Bool)
    case failed(String)
}

enum ThirdPartyProxyError: LocalizedError, Equatable {
    case invalidResponse
    case moduleNotIntercepted
    case rejected(String)
    case coordinateMismatch
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return AppLocalization.string("第三方代理返回了无法识别的数据")
        case .moduleNotIntercepted:
            return AppLocalization.string("请求未被第三方代理模块拦截，请检查模块、MITM 和代理连接")
        case .rejected(let message):
            return message
        case .coordinateMismatch:
            return AppLocalization.string("第三方代理保存的坐标与当前选点不一致")
        case .network(let message):
            return AppLocalization.string("第三方代理请求失败：\(message)")
        }
    }

    var recoverySuggestion: String {
        return AppLocalization.string("检查模块、MITM、证书和代理/VPN连接")
    }

    static func recoverySuggestion(for error: Error) -> String {
        (error as? Self)?.recoverySuggestion
            ?? AppLocalization.string("检查模块、MITM、证书和代理/VPN连接")
    }
}

protocol ThirdPartyProxyRequesting {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ThirdPartyProxyRequesting {}

@MainActor
final class ThirdPartyProxyManager: ObservableObject {
    static let shared = ThirdPartyProxyManager()
    static let interceptionHostnames = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com",
        "gsp-ssl.ls.apple.com",
        "bluedot.is.autonavi.com",
        "bluedot.is.autonavi.com.gds.alibabadns.com"
    ]
    static let configurationEndpoint = URL(string: "https://gs-loc.apple.com/wloc-settings/save")!

    @Published private(set) var connectionState: ThirdPartyProxyConnectionState = .unknown
    @Published private(set) var activeSettings: ThirdPartyProxySettingsResponse?
    @Published private(set) var isRequesting = false
    private let requester: any ThirdPartyProxyRequesting

    init(requester: (any ThirdPartyProxyRequesting)? = nil) {
        if let requester {
            self.requester = requester
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            self.requester = URLSession(configuration: configuration)
        }
    }

    func query() async throws -> ThirdPartyProxySettingsResponse {
        let response = try await perform(action: .query)
        let active = try validatedQueryState(response)
        if active {
            activeSettings = response
            connectionState = .connected(active: true)
        } else {
            activeSettings = nil
            connectionState = .connected(active: false)
        }
        return response
    }

    func save(_ favorite: FavoriteLocation) async throws -> ThirdPartyProxySettingsResponse {
        let wgs84 = favorite.coordinatePair.wgs84
        let response = try await perform(action: .save(
            latitude: wgs84.latitude,
            longitude: wgs84.longitude,
            accuracy: favorite.accuracy,
            randomRadius: RandomRadiusStore.shared.isEnabled ? RandomRadiusStore.shared.radius : 0
        ))
        guard response.success else {
            throw ThirdPartyProxyError.rejected(response.error ?? AppLocalization.string("第三方代理拒绝保存坐标"))
        }
        guard let latitude = response.latitude,
              let longitude = response.longitude,
              abs(latitude - wgs84.latitude) <= 0.000_001,
              abs(longitude - wgs84.longitude) <= 0.000_001 else {
            throw ThirdPartyProxyError.coordinateMismatch
        }
        activeSettings = response
        connectionState = .connected(active: true)
        RuntimeLogger.info("APP", "ThirdPartyProxy", "第三方代理已保存 WGS-84 坐标", details: [
            "坐标标准": "WGS-84",
            "取值字段": "coordinatePair.wgs84",
            "accuracy": String(favorite.accuracy)
        ])
        return response
    }

    func clear() async throws {
        let response = try await perform(action: .clear)
        guard response.success else {
            throw ThirdPartyProxyError.rejected(response.error ?? AppLocalization.string("第三方代理清除坐标失败"))
        }
        activeSettings = nil
        connectionState = .connected(active: false)
        RuntimeLogger.info("APP", "ThirdPartyProxy", "第三方代理坐标已清除")
    }

    private func validatedQueryState(_ response: ThirdPartyProxySettingsResponse) throws -> Bool {
        if response.success,
           response.latitude != nil,
           response.longitude != nil {
            return true
        }
        if response.error?.contains("无已保存") == true {
            return false
        }
        throw ThirdPartyProxyError.rejected(response.error ?? AppLocalization.string("第三方代理查询失败"))
    }

    private enum Action {
        case query
        case save(latitude: Double, longitude: Double, accuracy: Int, randomRadius: Double)
        case clear
    }

    private func perform(action: Action) async throws -> ThirdPartyProxySettingsResponse {
        guard !isRequesting else {
            throw ThirdPartyProxyError.rejected(AppLocalization.string("已有第三方代理请求正在执行"))
        }
        isRequesting = true
        defer { isRequesting = false }

        var components = URLComponents(url: Self.configurationEndpoint, resolvingAgainstBaseURL: false)!
        switch action {
        case .query:
            components.queryItems = [URLQueryItem(name: "action", value: "query")]
        case .clear:
            components.queryItems = [URLQueryItem(name: "action", value: "clear")]
        case .save(let latitude, let longitude, let accuracy, let randomRadius):
            components.queryItems = [
                URLQueryItem(name: "lon", value: String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), longitude)),
                URLQueryItem(name: "lat", value: String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), latitude)),
                URLQueryItem(name: "acc", value: String(accuracy)),
                URLQueryItem(
                    name: "randomRadius",
                    value: String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), randomRadius)
                )
            ]
        }
        guard let url = components.url else { throw ThirdPartyProxyError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8

        do {
            let (data, urlResponse) = try await requester.data(for: request)
            guard let http = urlResponse as? HTTPURLResponse, http.statusCode == 200 else {
                throw ThirdPartyProxyError.moduleNotIntercepted
            }
            guard let response = try? JSONDecoder().decode(ThirdPartyProxySettingsResponse.self, from: data) else {
                throw ThirdPartyProxyError.moduleNotIntercepted
            }

            return response
        } catch let error as ThirdPartyProxyError {
            connectionState = .failed(error.localizedDescription)
            RuntimeLogger.error("APP", "ThirdPartyProxy", "第三方代理请求失败", error: error)
            throw error
        } catch {
            let mapped = ThirdPartyProxyError.network(error.localizedDescription)
            connectionState = .failed(mapped.localizedDescription)
            RuntimeLogger.error("APP", "ThirdPartyProxy", "第三方代理请求失败", error: error)
            throw mapped
        }
    }
}

enum ThirdPartyProxyClient: String, CaseIterable, Identifiable {
    /// Bump when a hosted module or script changes to invalidate proxy-client caches.
    static let moduleSubscriptionVersion = "1.0.8"

    case shadowrocket
    case surge
    case quantumultX
    case loon
    case stash
    case egern

    var id: String { rawValue }

    var name: String {
        switch self {
        case .shadowrocket: return "Shadowrocket"
        case .surge: return "Surge"
        case .quantumultX: return "Quantumult X"
        case .loon: return "Loon"
        case .stash: return "Stash"
        case .egern: return "Egern"
        }
    }

    var verificationText: String? {
        self == .shadowrocket ? nil : AppLocalization.string("配置已提供，尚未验证")
    }

    var moduleFileName: String {
        switch self {
        case .shadowrocket: return "wloc.module"
        case .surge, .egern: return "wloc.sgmodule"
        case .quantumultX: return "wloc.conf"
        case .loon: return "wloc.lpx"
        case .stash: return "wloc.stoverride"
        }
    }

    @MainActor
    var subscriptionURL: URL {
        let directory = ThirdPartyModuleSourceStore.shared.useMirror
            ? "Resources/ThirdPartyProxyModules"
            : "ThirdParty/WlocScripts/modules/direct"
        let prefix = ThirdPartyModuleSourceStore.shared.useMirror
            ? "https://gh-proxy.org/https://raw.githubusercontent.com/xweiba/location-spoofer/main/"
            : "https://raw.githubusercontent.com/xweiba/location-spoofer/main/"
        let base = "\(prefix)\(directory)/\(moduleFileName)"
        return URL(string: "\(base)?v=\(Self.moduleSubscriptionVersion)")!
    }

    var launchURL: URL? {
        switch self {
        case .shadowrocket: return URL(string: "shadowrocket://")
        case .surge: return URL(string: "surge://")
        case .quantumultX: return URL(string: "quantumult-x://")
        case .loon: return URL(string: "loon://")
        case .stash: return URL(string: "stash://")
        case .egern: return URL(string: "egern://")
        }
    }
}

@MainActor
final class ThirdPartyProxyClientStore: ObservableObject {
    static let shared = ThirdPartyProxyClientStore()

    private enum Key {
        static let selectedClient = "selectedThirdPartyProxyClient"
    }

    @Published private(set) var selectedClient: ThirdPartyProxyClient
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        selectedClient = defaults.string(forKey: Key.selectedClient)
            .flatMap(ThirdPartyProxyClient.init(rawValue:)) ?? .shadowrocket
    }

    func select(_ client: ThirdPartyProxyClient) {
        selectedClient = client
        defaults.set(client.rawValue, forKey: Key.selectedClient)
    }
}
