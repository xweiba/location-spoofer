import Foundation

enum ProxyRuntimeMode: String, CaseIterable, Codable, Identifiable {
    case localWiFi
    case thirdParty
    case builtInVPN

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localWiFi: return "APP模式"
        case .thirdParty: return "第三方代理模式"
        case .builtInVPN: return "内置VPN模式"
        }
    }
}

@MainActor
final class ProxyRuntimeModeStore: ObservableObject {
    static let shared = ProxyRuntimeModeStore()

    private enum Key {
        static let runtimeMode = "proxyRuntimeMode"
        static let hasSelectedRuntimeMode = "hasSelectedProxyRuntimeMode"
        static let localWiFiInitialized = "localWiFiRuntimeModeInitialized"
        static let thirdPartyInitialized = "thirdPartyRuntimeModeInitialized"
        static let builtInVPNInitialized = "builtInVPNRuntimeModeInitialized"
        static let initializationMigrationCompleted = "runtimeModeInitializationMigrationCompleted"
        static let legacySetupCompleted = "setupCompleted"
    }

    @Published private(set) var mode: ProxyRuntimeMode
    @Published private(set) var hasSelectedMode: Bool
    @Published private(set) var localWiFiInitialized: Bool
    @Published private(set) var thirdPartyInitialized: Bool
    @Published private(set) var builtInVPNInitialized: Bool
    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults

    init(
        defaults: UserDefaults = AppGroup.defaults,
        legacyDefaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults
        self.mode = defaults.string(forKey: Key.runtimeMode)
            .flatMap(ProxyRuntimeMode.init(rawValue:)) ?? .localWiFi
        self.hasSelectedMode = defaults.bool(forKey: Key.hasSelectedRuntimeMode)
        self.localWiFiInitialized = defaults.bool(forKey: Key.localWiFiInitialized)
        self.thirdPartyInitialized = defaults.bool(forKey: Key.thirdPartyInitialized)
        self.builtInVPNInitialized = defaults.bool(forKey: Key.builtInVPNInitialized)
        migrateLegacyInitializationIfNeeded()
    }

    func setMode(_ mode: ProxyRuntimeMode) {
        let changed = self.mode != mode
        self.mode = mode
        hasSelectedMode = true
        defaults.set(mode.rawValue, forKey: Key.runtimeMode)
        defaults.set(true, forKey: Key.hasSelectedRuntimeMode)
        migrateLegacyInitializationIfNeeded()
        if changed {
            RuntimeLogger.info("APP", "Mode", "代理运行模式已切换", details: [
                "模式": mode.displayName
            ])
        }
    }

    func isInitialized(_ mode: ProxyRuntimeMode) -> Bool {
        switch mode {
        case .localWiFi: return localWiFiInitialized
        case .thirdParty: return thirdPartyInitialized
        case .builtInVPN: return builtInVPNInitialized
        }
    }

    func markInitialized(_ mode: ProxyRuntimeMode) {
        setInitialized(true, for: mode)
    }

    func resetInitialization(_ mode: ProxyRuntimeMode) {
        setInitialized(false, for: mode)
    }

    private func setInitialized(_ initialized: Bool, for mode: ProxyRuntimeMode) {
        switch mode {
        case .localWiFi:
            localWiFiInitialized = initialized
            defaults.set(initialized, forKey: Key.localWiFiInitialized)
        case .thirdParty:
            thirdPartyInitialized = initialized
            defaults.set(initialized, forKey: Key.thirdPartyInitialized)
        case .builtInVPN:
            builtInVPNInitialized = initialized
            defaults.set(initialized, forKey: Key.builtInVPNInitialized)
        }
    }

    private func migrateLegacyInitializationIfNeeded() {
        guard hasSelectedMode,
              !defaults.bool(forKey: Key.initializationMigrationCompleted) else {
            return
        }
        if legacyDefaults.bool(forKey: Key.legacySetupCompleted) {
            setInitialized(true, for: mode)
            RuntimeLogger.info("APP", "Mode", "已迁移旧版模式初始化状态", details: [
                "模式": mode.displayName
            ])
        }
        defaults.set(true, forKey: Key.initializationMigrationCompleted)
    }
}
