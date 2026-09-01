import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var setup = SetupCoordinator()
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared
    @State private var phase: AppPhase = .splash
    @State private var updatePrompt: AppUpdatePrompt?
    @State private var requiredUpdatePrompt: AppUpdatePrompt?

    enum AppPhase { case splash, setup, map }

    var body: some View {
        Group {
            switch phase {
            case .splash:
                VStack(spacing: 16) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 48)).foregroundStyle(.blue)
                    ProgressView()
                    Text(runtimeMode.hasSelectedMode && runtimeMode.mode == .localWiFi
                         ? "正在初始化地图与本地代理…"
                         : "正在初始化地图…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            case .setup:
                FirstSetupView(setup: setup, onComplete: finishInitialSetup)
            case .map:
                NavigationView {
                    MapHomeView(setup: setup)
                }
                .fullScreenCover(isPresented: $setup.needsSetup) {
                    FirstSetupView(setup: setup, onComplete: finishPresentedSetup)
                }
            }
        }
        .task { await bootstrap() }
        .task { await checkForUpdates() }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active, let requiredUpdatePrompt else { return }
            updatePrompt = requiredUpdatePrompt
        }
        .alert(item: $updatePrompt) { prompt in
            updateAlert(for: prompt)
        }
    }

    @MainActor
    private func bootstrap() async {
        guard runtimeMode.hasSelectedMode else {
            ProxyManager.shared.stop()
            RuntimeLogger.info("APP", "Startup", "尚未选择运行模式，跳过本地 CA 和代理初始化")
            setup.requestModeSelection()
            phase = .setup
            return
        }

        let launchMode = runtimeMode.mode
        guard runtimeMode.isInitialized(launchMode) else {
            switch launchMode {
            case .localWiFi:
                await setup.prepareLocalServices()
                setup.requestSetup()
            case .builtInVPN:
                ProxyManager.shared.stop()
                BackgroundKeepAlive.shared.stop()
                await setup.prepareVPNServices()
                setup.requestVPNSetup()
            case .thirdParty:
                ProxyManager.shared.stop()
                BackgroundKeepAlive.shared.stop()
                setup.requestThirdPartyOnboarding()
            }
            phase = .setup
            return
        }

        switch launchMode {
        case .localWiFi:
            await setup.prepareLocalServices()
        case .builtInVPN:
            await setup.prepareVPNServices()
            RuntimeLogger.info("APP", "Startup", "内置 VPN 模式：后台自动连接隧道")
            Task { @MainActor in
                try? await BuiltInVPNManager.shared.connect()
            }
        case .thirdParty:
            ProxyManager.shared.stop()
            BackgroundKeepAlive.shared.stop()
            RuntimeLogger.info("APP", "Startup", "第三方代理测试模式：跳过本地 CA、代理和环境检测")
        }
        do {
            try CoordinateStorageMigration.migrateIfNeeded(favorites: FavoriteLocationStore())
        } catch {
            RuntimeLogger.error("APP", "Startup", "旧坐标数据迁移失败，将在下次启动重试", error: error)
        }

        // MapHomeView is intentionally constructed only after this required
        // coordinate-system gate resolves, so cached pins are never replayed
        // into an unknown Apple Maps coordinate system.
        let mapCoordinateSystem = await CoordinateConverter.resolveInitialMapCoordinateSystem()
        guard !Task.isCancelled else { return }
        RuntimeLogger.info("APP", "Startup", "地图坐标标准初始化完成，开始后续启动流程", details: [
            "地图标准": mapCoordinateSystem.rawValue,
            "使用兜底": String(CoordinateConverter.initialMapCoordinateSystemUsedFallback)
        ])

        // Resolve the first map center before constructing MapHomeView. This
        // prevents a Shenzhen/cache frame followed by a second realtime frame.
        if LastCoordinateStore.load() == nil {
            RuntimeLogger.info("APP", "Startup", "没有持久化图钉，地图创建前请求实时定位")
            if let realtime = await RealtimeLocationManager.shared.requestLocation() {
                let mapCoordinateSystemChange = CoordinateConverter.correctMapCoordinateSystemUsingRealtime(realtime)
                let pair = CoordinateConverter.coordinatePair(
                    lat: realtime.latitude,
                    lon: realtime.longitude,
                    mapCoordinateSystem: .wgs84
                )
                LastCoordinateStore.save(coordinatePair: pair, zoomMeters: 1_000)
                RuntimeLogger.info("APP", "Startup", "已使用实时定位准备唯一初始地图状态", details: [
                    "地图标准": CoordinateConverter.currentMapCoordinateSystem.rawValue,
                    "修正兜底标准": String(mapCoordinateSystemChange != nil),
                    "缩放米": "1000"
                ])
                RealtimeLocationTrace.coordinate(
                    "地图创建前取得的初始实时位置（WGS-84）",
                    coordinate: realtime
                )
            } else {
                RuntimeLogger.warning("APP", "Startup", "地图创建前无法取得实时定位，唯一初始位置使用深圳", details: [
                    "地图标准": mapCoordinateSystem.rawValue,
                    "缩放米": "1000"
                ])
            }
        } else {
            RuntimeLogger.info("APP", "Startup", "已找到持久化图钉，直接准备唯一初始地图状态")
        }
        guard !Task.isCancelled else { return }

        setup.completeSetup()
        RuntimeLogger.info("APP", "Startup", "启动门禁全部完成，现在创建 MapHomeView")
        phase = .map
    }

    private func finishInitialSetup() {
        let completedMode = runtimeMode.mode
        runtimeMode.markInitialized(completedMode)
        setup.completeSetup()
        phase = .splash
        Task { await bootstrap() }
    }

    private func finishPresentedSetup() {
        runtimeMode.markInitialized(runtimeMode.mode)
        setup.completeSetup()
    }

    @MainActor
    private func checkForUpdates() async {
        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? AppRemoteConfiguration.fallback.latestVersion
        let configuration: AppRemoteConfiguration
        if let remote = await AppRemoteConfigurationService.fetch() {
            remoteConfiguration.apply(remote)
            configuration = remote
        } else {
            configuration = remoteConfiguration.configuration
        }
        guard let pendingPrompt = configuration.updatePrompt(currentVersion: currentVersion) else { return }
        let releaseNotes = await AppRemoteConfigurationService.fetchReleaseNotes(
            version: pendingPrompt.latestVersion
        )
        guard !Task.isCancelled,
              let prompt = configuration.updatePrompt(
                currentVersion: currentVersion,
                releaseNotes: releaseNotes
              ) else {
            return
        }
        if prompt.requirement == .required {
            requiredUpdatePrompt = prompt
        }
        updatePrompt = prompt
    }

    private func updateAlert(for prompt: AppUpdatePrompt) -> Alert {
        switch prompt.requirement {
        case .required:
            let details = prompt.releaseNotes
                ?? "更新说明暂时无法加载，请前往最新 Release 页面查看。"
            return Alert(
                title: Text("需要更新"),
                message: Text(
                    "当前版本 \(prompt.currentVersion) 已停止支持，请更新到 \(prompt.latestVersion) 后继续使用。\n\n\(details)"
                ),
                dismissButton: .default(Text("立即更新")) {
                    openUpdatePage(requiredPrompt: prompt)
                }
            )
        case .recommended:
            let details = prompt.releaseNotes
                ?? "更新说明暂时无法加载，请前往最新 Release 页面查看。"
            return Alert(
                title: Text("发现新版本"),
                message: Text(
                    "当前版本 \(prompt.currentVersion)，最新版本 \(prompt.latestVersion)。\n\n\(details)"
                ),
                primaryButton: .default(Text("前往更新")) {
                    openUpdatePage(requiredPrompt: nil)
                },
                secondaryButton: .cancel(Text("稍后"))
            )
        }
    }

    private func openUpdatePage(requiredPrompt: AppUpdatePrompt?) {
        UIApplication.shared.open(AppRemoteConfigurationService.releasesURL)
        guard requiredPrompt != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            updatePrompt = self.requiredUpdatePrompt
        }
    }
}
