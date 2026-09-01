import Foundation
import NetworkExtension

enum BuiltInVPNError: LocalizedError {
    case missingCertificateAuthority
    case notConnected
    case startFailed(String)
    case connectionTimeout
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .missingCertificateAuthority: return "未找到本地 CA 证书，请先在 App 内初始化证书"
        case .notConnected: return "内置 VPN 未连接"
        case .startFailed(let detail): return detail
        case .permissionDenied:
            return """
            系统拒绝了 VPN 启动。请按以下步骤处理：
            1. 重试启用，如弹出「允许添加 VPN 配置」请选择「允许」；
            2. 若此前点过「不允许」，请到 设置 → 通用 → VPN 与设备管理 删除「Paopao 内置VPN」后再试；
            3. 确认设备没有开启其他 VPN。
            """
        case .connectionTimeout:
            return """
            VPN 启动超时。常见原因：
            1. 使用了免费个人开发者账号签名（内置 VPN 需要付费开发者账号的 NetworkExtension 权限）；
            2. 首次启动时未在系统弹窗中允许添加 VPN 配置；
            3. 设备正在使用其他 VPN。
            """
        }
    }
}

@MainActor
final class BuiltInVPNManager: ObservableObject {
    static let shared = BuiltInVPNManager()

    private enum Constants {
        static let providerBundleID = "com.paopaolabs.location-spoofer.vpn"
        static let localizedDescription = "Paopao 内置VPN"
        static let connectTimeout: TimeInterval = 30
        static let targetHosts = ["gs-loc.apple.com", "gs-loc-cn.apple.com"]
    }

    enum ConfigKey {
        static let certPEM = "caCertPEM"
        static let keyPEM = "caKeyPEM"
        static let latitude = "latitude"
        static let longitude = "longitude"
        static let enabled = "enabled"
        static let accuracy = "accuracy"
        static let motionEnabled = "motionEnabled"
        static let routeIPs = "routeIPs"
        static let hostsMapping = "hostsMapping"
    }

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isBusy = false

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor in
                self?.status = connection.status
            }
        }
    }

    var isConnected: Bool { status == .connected }

    // MARK: - Connect / disconnect

    func connect() async throws {
        if isConnected { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let authority = try loadCertificateAuthority()
        do {
            try await configureAndStart(authority: authority)
            return
        } catch let error as BuiltInVPNError {
            throw error
        } catch {
            guard Self.isPermissionDenied(error) else {
                RuntimeLogger.error("APP", "VPN", "内置 VPN 启动失败", error: error)
                throw BuiltInVPNError.startFailed(Self.describeStartError(error))
            }
            let ns = error as NSError
            RuntimeLogger.warning("APP", "VPN", "VPN 启动被拒（系统授权弹窗可能正在等待用户响应），将等待后重试", details: [
                "errorDomain": ns.domain,
                "errorCode": String(ns.code)
            ])
        }

        // 首次被拒通常对应系统刚弹出「允许添加 VPN 配置」授权框：
        // 该调用会立即返回 permission denied，只有用户点「允许」后重试才会成功。
        // 给用户留出响应时间，间隔重试；顺带清理历史残留配置。
        let retryDelays: [TimeInterval] = [2, 3, 3, 3, 3, 3]
        for (attempt, delay) in retryDelays.enumerated() {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if isConnected { return }
            if attempt > 0 {
                manager = nil
                try? await removeExistingConfiguration()
            }
            do {
                try await configureAndStart(authority: authority)
                return
            } catch let error as BuiltInVPNError {
                throw error
            } catch {
                if !Self.isPermissionDenied(error) {
                    RuntimeLogger.error("APP", "VPN", "重试启动内置 VPN 失败", error: error)
                    throw BuiltInVPNError.startFailed(Self.describeStartError(error))
                }
                RuntimeLogger.warning("APP", "VPN", "VPN 重试仍被拒，继续等待用户授权", details: [
                    "attempt": String(attempt + 1)
                ])
            }
        }
        throw BuiltInVPNError.permissionDenied
    }

    private func configureAndStart(authority: CertificateAuthority) async throws {
        let manager = try await loadOrCreateManager()
        manager.protocolConfiguration = makeProtocol(authority: authority)
        manager.localizedDescription = Constants.localizedDescription
        manager.isOnDemandEnabled = false
        do {
            try await manager.saveToPreferences()
            RuntimeLogger.info("APP", "VPN", "VPN 配置已保存")
        } catch {
            RuntimeLogger.error("APP", "VPN", "saveToPreferences 失败", error: error)
            throw error
        }
        do {
            try await manager.loadFromPreferences()
            RuntimeLogger.info("APP", "VPN", "VPN 配置已加载 isEnabled=\(manager.isEnabled)")
        } catch {
            RuntimeLogger.error("APP", "VPN", "loadFromPreferences 失败", error: error)
            throw error
        }
        if !manager.isEnabled {
            manager.isEnabled = true
            do {
                try await manager.saveToPreferences()
                RuntimeLogger.info("APP", "VPN", "VPN 配置已启用")
            } catch {
                // 启用保存可能被系统拒绝（授权弹窗被抑制等），非致命，继续尝试直接启动。
                let ns = error as NSError
                RuntimeLogger.warning("APP", "VPN", "启用配置的保存被拒，忽略并尝试直接启动", details: [
                    "errorDomain": ns.domain,
                    "errorCode": String(ns.code)
                ])
            }
        }
        RuntimeLogger.info("APP", "VPN", "请求启动内置 VPN")
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            RuntimeLogger.error("APP", "VPN", "startVPNTunnel 失败", error: error)
            throw error
        }
        RuntimeLogger.info("APP", "VPN", "startVPNTunnel 已接受，等待连接")
        try await waitForConnected()
    }

    private func removeExistingConfiguration() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        for existing in managers {
            let proto = existing.protocolConfiguration as? NETunnelProviderProtocol
            guard proto?.providerBundleIdentifier == Constants.providerBundleID else { continue }
            try await existing.removeFromPreferences()
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == EACCES { return true }
        let text = ns.localizedDescription.lowercased()
        return text.contains("permission denied") || text.contains("not permitted")
    }

    func disconnect() {
        guard let manager, status != .disconnected, status != .invalid else { return }
        RuntimeLogger.info("APP", "VPN", "请求断开内置 VPN")
        manager.connection.stopVPNTunnel()
    }

    // MARK: - Runtime messages

    func sendPatchConfig(lat: Double, lon: Double, enabled: Bool, accuracy: Int, motionEnabled: Bool) {
        guard isConnected else {
            RuntimeLogger.warning("APP", "VPN", "隧道未连接，跳过坐标下发")
            return
        }
        Task {
            _ = try? await sendMessage([
                "type": "patchConfig",
                ConfigKey.latitude: lat,
                ConfigKey.longitude: lon,
                ConfigKey.enabled: enabled,
                ConfigKey.accuracy: accuracy,
                ConfigKey.motionEnabled: motionEnabled
            ])
            RuntimeLogger.info("APP", "VPN", "已向隧道下发坐标", details: [
                "enabled": String(enabled)
            ])
        }
    }

    func setExtraHosts(_ hosts: [String]) async throws {
        let mapping = Self.resolveHosts(hosts)
        _ = try await sendMessage([
            "type": "setExtraHosts",
            ConfigKey.hostsMapping: mapping
        ])
    }

    func requestVerifyToken() async throws -> String {
        let response = try await sendMessage(["type": "refreshVerifyToken"])
        return response["token"] as? String ?? ""
    }

    func drainExtensionLogs() async -> String {
        guard let response = try? await sendMessage(["type": "drainLogs"]) else { return "" }
        return response["logs"] as? String ?? ""
    }

    // MARK: - Internals

    private func loadCertificateAuthority() throws -> CertificateAuthority {
        guard let authority = try CertificateAuthorityStore().load(),
              CoreBridge.isValidCertificateAuthority(authority) else {
            throw BuiltInVPNError.missingCertificateAuthority
        }
        return authority
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first(where: { manager in
            let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
            return proto?.providerBundleIdentifier == Constants.providerBundleID
        }) {
            manager = existing
            status = existing.connection.status
            return existing
        }
        let created = NETunnelProviderManager()
        manager = created
        return created
    }

    private func makeProtocol(authority: CertificateAuthority) -> NETunnelProviderProtocol {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Constants.providerBundleID
        // serverAddress 是 NEVPNProtocol 的必填项，缺失会导致系统以
        // "Missing server address" 拒绝保存/启动配置。
        proto.serverAddress = "127.0.0.1"
        var config: [String: Any] = [
            ConfigKey.certPEM: authority.certPEM,
            ConfigKey.keyPEM: authority.keyPEM,
            ConfigKey.motionEnabled: MotionSimulationStore.shared.isEnabled
        ]
        if let settings = WlocSettingsStore.load(), settings.enabled {
            config[ConfigKey.latitude] = settings.latitude
            config[ConfigKey.longitude] = settings.longitude
            config[ConfigKey.enabled] = true
            config[ConfigKey.accuracy] = settings.accuracy
        } else {
            config[ConfigKey.enabled] = false
            config[ConfigKey.accuracy] = 25
        }
        let routeIPs = Self.resolveHosts(Constants.targetHosts)
        if let data = try? JSONSerialization.data(withJSONObject: routeIPs),
           let json = String(data: data, encoding: .utf8) {
            config[ConfigKey.routeIPs] = json
        }
        RuntimeLogger.info("APP", "VPN", "已预解析定位域名路由", details: ["routeIPs": String(routeIPs.count)])
        proto.providerConfiguration = config
        return proto
    }

    /// App 进程网络可靠，DNS 在这里做；Network Extension 内 getaddrinfo 可能阻塞。
    static func resolveHosts(_ hosts: [String]) -> [String: String] {
        var mapping: [String: String] = [:]
        for host in hosts {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
                continue
            }
            defer { freeaddrinfo(result) }
            var node: UnsafeMutablePointer<addrinfo>? = first
            while let current = node {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    current.pointee.ai_addr,
                    current.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let ip = String(cString: buffer)
                    let cleaned = ip.split(separator: "%").first.map(String.init) ?? ip
                    if !cleaned.isEmpty { mapping[cleaned] = host }
                }
                node = current.pointee.ai_next
            }
        }
        return mapping
    }

    private func waitForConnected() async throws {
        let deadline = Date().addingTimeInterval(Constants.connectTimeout)
        var sawProgress = false
        while Date() < deadline {
            switch status {
            case .connected:
                RuntimeLogger.info("APP", "VPN", "内置 VPN 已连接")
                return
            case .connecting, .reasserting:
                sawProgress = true
            case .invalid:
                if sawProgress { break }
                throw BuiltInVPNError.startFailed(Self.signingHint)
            default:
                break
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw BuiltInVPNError.connectionTimeout
    }

    private func sendMessage(_ object: [String: Any]) async throws -> [String: Any] {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            throw BuiltInVPNError.notConnected
        }
        guard session.status == .connected else {
            throw BuiltInVPNError.notConnected
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            do {
                try session.sendProviderMessage(data) { payload in
                    continuation.resume(returning: payload)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard let response, !response.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static let signingHint = """
    VPN 扩展未能加载。请确认：
    1. 使用付费 Apple Developer 账号签名（免费账号无法签发 NetworkExtension 权限）；
    2. 签名时为扩展注入了 packet-tunnel-provider entitlement。
    免费账号用户请改用 APP 模式或第三方代理模式。
    """

    private static func describeStartError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NEVPNErrorDomain {
            return "VPN 启动失败（错误码 \(ns.code)）。\(signingHint)"
        }
        return "VPN 启动失败：\(error.localizedDescription)"
    }
}
