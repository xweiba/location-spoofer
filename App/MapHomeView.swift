import SwiftUI
import MapKit
import UIKit
import CoreLocation

private struct SearchLocationResult: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
}

private enum HomeSheet: String, Identifiable {
    case settings, logs
    var id: String { rawValue }
}

private enum SpoofState {
    case idle, verifying, active
}

private struct RealtimeLocationRequestContext {
    let intent: RealtimeLocationIntent
    let source: String
    let showFailureAlert: Bool
}

private enum RealtimeCoordinateSource: Equatable {
    case mapKitBluePoint
    case coreLocation

    @MainActor
    var coordinateSystem: CoordinateConverter.MapCoordinateSystem {
        switch self {
        case .mapKitBluePoint: return CoordinateConverter.currentMapCoordinateSystem
        case .coreLocation: return .wgs84
        }
    }

    var diagnosticName: String {
        switch self {
        case .mapKitBluePoint: return "MapKit地图蓝点"
        case .coreLocation: return "CLLocationManager"
        }
    }
}

struct MapHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var setup: SetupCoordinator
    @StateObject private var favorites: FavoriteLocationStore
    @StateObject private var actions = LocationActionCoordinator()
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var vpnManager = BuiltInVPNManager.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject private var thirdPartyClient = ThirdPartyProxyClientStore.shared
    @ObservedObject private var remoteConfiguration = AppRemoteConfigurationStore.shared
    @StateObject private var realtime = RealtimeLocationManager.shared
    @StateObject private var mapState: MapLocationState
    @ObservedObject private var net = NetworkMonitor.shared

    @State private var searchText = ""
    @State private var searchResults: [SearchLocationResult] = []
    @State private var isSearching = false
    @State private var searchRequestID: UInt64 = 0
    @State private var searchError = ""
    @State private var mapRuntimeDidStart = false
    @State private var activeSheet: HomeSheet?
    @State private var showEnableTip = false
    @State private var showDisableTip = false
    @State private var activeTip: TipKind?
    @State private var manualHint = ""
    private let tipPreferences = VirtualLocationTipPreferences()
    private let communityPromptPreferences = ThirdPartyCommunityPromptPreferences()
    @State private var pendingCommunityContributionClient: ThirdPartyProxyClient?
    @State private var communityContributionClient: ThirdPartyProxyClient?
    @State private var showCommunityTemplateCopied = false
    @State private var githubDestination: SafariDestination?
    @State private var editingFavorite: FavoriteLocation?
    @State private var editName = ""
    @State private var reverseGeocodeTask: Task<Void, Never>?
    @State private var geocodeDebounceTask: Task<Void, Never>?
    @State private var showLocationAlert = false
    @State private var realtimeRequestTask: Task<Void, Never>?
    @State private var realtimeRequestContext: RealtimeLocationRequestContext?
    @State private var wifiChangeObserverToken: UUID?
    @State private var wifiVerificationTask: Task<Void, Never>?
    @State private var wifiVerificationID: UUID?
    @State private var copiedCoordinateSystem: CoordinateConverter.MapCoordinateSystem?
    @State private var spoofState: SpoofState = .idle
    @State private var locationOperationTask: Task<Void, Never>?
    @State private var locationOperationID: UInt64 = 0
    @State private var mapCoordinateSystemRefreshTask: Task<Void, Never>?
    @State private var mapCoordinateSystemRefreshID: UInt64 = 0
    @State private var bluePointRefreshPending = false
    @State private var realtimeButtonTask: Task<Void, Never>?
    @State private var favoriteSaveTask: Task<Void, Never>?
    // 激活时的坐标（本地存，绕过 C 桥接层精度丢失）
    @State private var activeSpoofLat: Double?
    @State private var activeSpoofLon: Double?
    @State private var lastSpoofDiagnosisSystem: CoordinateConverter.MapCoordinateSystem?
    @State private var hasLoggedSpoofDiagnosis = false

    init(setup: SetupCoordinator) {
        self.setup = setup
        let favoriteStore = FavoriteLocationStore()
        _favorites = StateObject(wrappedValue: favoriteStore)
        let savedCoord = LastCoordinateStore.load()
        let initialZoom = savedCoord?.zoomMeters ?? ViewportStore.loadOrDefault()
        let selectedFavorite = favoriteStore.selectedFavorite
        let initialCoord: CLLocationCoordinate2D
        let initialSource: MapSelectionSource
        let initialName: String?
        if let saved = savedCoord {
            initialCoord = saved.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            if let selectedFavorite,
               selectedFavorite.coordinatePair.matchesWGS84(
                   latitude: saved.coordinatePair.wgs84.latitude,
                   longitude: saved.coordinatePair.wgs84.longitude
               ) {
                initialSource = .favorite(selectedFavorite.id)
                initialName = selectedFavorite.name
            } else {
                initialSource = .initial
                initialName = nil
            }
        } else if let selectedFavorite {
            initialCoord = selectedFavorite.coordinatePair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            initialSource = .favorite(selectedFavorite.id)
            initialName = selectedFavorite.name
        } else {
            // The fallback location is defined as WGS-84 and rendered in the
            // coordinate system resolved by the startup gate.
            initialCoord = CoordinateConverter.coordinatePair(
                lat: 22.544577,
                lon: 113.94114,
                mapCoordinateSystem: .wgs84
            ).coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            initialSource = .initial
            initialName = nil
        }
        RuntimeLogger.info("APP", "地图", "初始化", details: [
            "zoom": String(initialZoom),
            "有缓存": String(savedCoord != nil),
            "初始来源": String(describing: initialSource),
            "地图标准": CoordinateConverter.currentMapCoordinateSystem.rawValue
        ])
        _mapState = StateObject(wrappedValue: MapLocationState(
            initialCoordinate: initialCoord,
            initialViewportMeters: initialZoom,
            initialSource: initialSource,
            initialName: initialName
        ))

        if ProxyRuntimeModeStore.shared.mode != .thirdParty,
           let settings = WlocSettingsStore.load(), settings.enabled {
            _spoofState = State(initialValue: .active)
            _activeSpoofLat = State(initialValue: settings.latitude)
            _activeSpoofLon = State(initialValue: settings.longitude)
        }
    }

    var body: some View {
        ZStack {
            MapViewRepresentable(
                selection: mapState.selection,
                initialViewportMeters: mapState.viewportMeters,
                cameraCommand: mapState.cameraCommand,
                onRealtimeLocationChanged: { location in
                    handleNativeRealtimeLocation(location)
                },
                onUserCenterChanged: { coordinate, distance in
                    mapState.updateViewport(distanceMeters: distance)
                    let previousRevision = mapState.selection.revision
                    let revision = mapState.selectUserMapCenter(coordinate)
                    guard revision != previousRevision else { return }
                    let pair = CoordinatePair(
                        mapCoordinate: coordinate,
                        mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
                    )
                    LastCoordinateStore.save(
                        coordinatePair: pair,
                        zoomMeters: mapState.viewportMeters
                    )
                    favorites.select(nil)
                    scheduleGeocode(pair: pair, revision: revision)
                },
                onViewportChanged: { distance in
                    mapState.updateViewport(distanceMeters: distance)
                },
                onMapTap: { coordinate in
                    favorites.select(nil)
                    let revision = mapState.selectMapTap(coordinate)
                    let pair = CoordinatePair(
                        mapCoordinate: coordinate,
                        mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
                    )
                    LastCoordinateStore.save(
                        coordinatePair: pair,
                        zoomMeters: mapState.viewportMeters
                    )
                    scheduleGeocode(pair: pair, revision: revision)
                },
                onUserZoomChanged: { distance in
                    ViewportStore.save(distance)
                    LastCoordinateStore.updateZoom(distance)
                },
                onZoomIn: { mapState.zoom(by: 0.5) },
                onZoomOut: { mapState.zoom(by: 2) }
            )
            .ignoresSafeArea(.container)

            VStack(spacing: 10) {
                topControls
                if !searchResults.isEmpty || !searchError.isEmpty { searchResultList }
                Spacer()
                // 右下角按钮
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Button {
                            if let url = URL(string: "maps://app") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "map.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        }
                        Button {
                            requestRealtimeLocation()
                        } label: {
                            if realtime.isRequesting {
                                ProgressView()
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            } else {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            }
                        }
                        .disabled(realtimeButtonTask != nil || realtimeRequestTask != nil || realtime.isRequesting)
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 8)
                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .navigationBarHidden(true)
        .sheet(item: $activeSheet) { sheet in
            NavigationView {
                switch sheet {
                case .settings: SettingsView(setup: setup, actions: actions)
                case .logs: RuntimeLogsView(setup: setup, actions: actions, testFavorite: testFavorite)
                }
            }
        }
        .sheet(item: $activeTip) { kind in
            TipSheetView(kind: kind, runtimeMode: runtimeMode.mode)
        }
        .sheet(item: $githubDestination) { destination in
            SafariView(url: destination.url)
                .ignoresSafeArea()
        }
        .alert("社区分享成功配置？", isPresented: Binding(
            get: { communityContributionClient != nil },
            set: { if !$0 { communityContributionClient = nil } }
        )) {
            Button("去提交") {
                guard let client = communityContributionClient else { return }
                UIPasteboard.general.string = GitHubSubmission.communityContributionTemplate(
                    for: client,
                    systemVersion: UIDevice.current.systemVersion
                )
                openCommunityContributionPage()
            }
            Button("复制模板") {
                guard let client = communityContributionClient else { return }
                UIPasteboard.general.string = GitHubSubmission.communityContributionTemplate(
                    for: client,
                    systemVersion: UIDevice.current.systemVersion
                )
                showCommunityTemplateCopied = true
            }
            if communityPromptPreferences.canSuppress() {
                Button("不再提示", role: .cancel) {
                    communityPromptPreferences.suppress()
                }
            } else {
                Button("取消", role: .cancel) {}
            }
        } message: {
            Text(
                "你正在使用 \(communityContributionClient?.name ?? "第三方客户端")。点击“去提交”会先复制投稿模板，并在 App 内打开社区页面。采纳后将收录到 README，可选择是否匿名署名。"
            )
        }
        .alert("已复制投稿模板", isPresented: $showCommunityTemplateCopied) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("如果 GitHub 登录或浏览器跳转后模板没有自动填充，可以直接粘贴。")
        }
        .alert("无法直接跳转", isPresented: Binding(
            get: { !manualHint.isEmpty },
            set: { if !$0 { manualHint = "" } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: { Text(manualHint) }
        .onAppear {
            startMapRuntimeOnce()
            if runtimeMode.mode == .localWiFi {
                registerWiFiChangeObserver()
            } else if runtimeMode.mode == .builtInVPN {
                spoofState = actions.virtualLocationEnabled ? .active : .idle
            } else {
                refreshThirdPartyState()
            }
        }
        .onDisappear {
            if let token = wifiChangeObserverToken {
                net.removeWiFiChangeObserver(token)
                wifiChangeObserverToken = nil
            }
            wifiVerificationTask?.cancel()
            wifiVerificationTask = nil
            wifiVerificationID = nil
            mapCoordinateSystemRefreshTask?.cancel()
            mapCoordinateSystemRefreshTask = nil
            bluePointRefreshPending = false
            realtimeButtonTask?.cancel()
            realtimeButtonTask = nil
            favoriteSaveTask?.cancel()
            favoriteSaveTask = nil
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { @MainActor in
                await awaitCoordinatedMapCoordinateSystemRefresh(reason: "App回到前台")
            }
        }
        .onChange(of: proxy.isRunning) { running in
            if runtimeMode.mode == .localWiFi, !running && spoofState == .active {
                spoofState = .idle
                actions.clear()
            }
        }
        .onChange(of: vpnManager.status) { newStatus in
            if runtimeMode.mode == .builtInVPN, newStatus != .connected && spoofState == .active {
                spoofState = .idle
                actions.clear()
            }
        }
        .onChange(of: showEnableTip) { isPresented in
            guard !isPresented, let client = pendingCommunityContributionClient else { return }
            pendingCommunityContributionClient = nil
            DispatchQueue.main.async {
                communityContributionClient = client
            }
        }
        .onChange(of: runtimeMode.mode) { mode in
            locationOperationTask?.cancel()
            locationOperationTask = nil
            locationOperationID &+= 1
            if let token = wifiChangeObserverToken {
                net.removeWiFiChangeObserver(token)
                wifiChangeObserverToken = nil
            }
            wifiVerificationTask?.cancel()
            wifiVerificationTask = nil
            activeSpoofLat = nil
            activeSpoofLon = nil
            if mode == .localWiFi {
                spoofState = actions.virtualLocationEnabled ? .active : .idle
                registerWiFiChangeObserver()
            } else if mode == .builtInVPN {
                spoofState = actions.virtualLocationEnabled ? .active : .idle
            } else {
                spoofState = .idle
                refreshThirdPartyState()
            }
        }
        .sheet(isPresented: $showEnableTip) { enableTipSheet }
        .sheet(isPresented: $showDisableTip) { disableTipSheet }
        .alert("定位失败", isPresented: $showLocationAlert) {
            Button("打开设置") {
                openSettings(.locationServices)
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text("无法获取当前定位，请检查定位服务是否已开启")
        }
        .alert("编辑收藏名称", isPresented: Binding(
            get: { editingFavorite != nil },
            set: { if !$0 { editingFavorite = nil } }
        )) {
            TextField("名称", text: $editName)
            Button("保存") {
                if let f = editingFavorite {
                    let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalName = name.isEmpty ? f.name : name
                    favorites.rename(f.id, to: finalName)
                    mapState.updateExplicitName(finalName, forFavoriteID: f.id)
                }
                editingFavorite = nil
            }
            Button("取消", role: .cancel) { editingFavorite = nil }
        } message: { Text("修改收藏地点名称") }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索地点或坐标", text: $searchText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).onSubmit(doSearch)
                if isSearching { ProgressView().controlSize(.small) }
                else if !searchText.isEmpty {
                    Button {
                        searchRequestID &+= 1
                        isSearching = false
                        searchText = ""
                        searchResults = []
                        searchError = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                Button(action: doSearch) { Image(systemName: "arrow.right.circle.fill").font(.title3) }
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            .padding(.horizontal, 14).frame(height: 48)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.13), radius: 9, y: 4)
            Menu {
                Button { activeSheet = .logs } label: { Label("日志", systemImage: "list.bullet.rectangle") }
                Button { activeSheet = .settings } label: { Label("设置", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold))
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.13), radius: 9, y: 4)
                    .contentShape(Circle())
            }.accessibilityLabel("更多")
        }
    }

    // 搜索列表：动态高度，不写死
    private var searchResultList: some View {
        VStack(spacing: 0) {
            if !searchError.isEmpty {
                Text(searchError).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            ForEach(searchResults) { r in
                HStack(spacing: 8) {
                    Button { selectSearchResult(r) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button(role: .destructive) { deleteSearchResult(r) } label: {
                        Image(systemName: "trash").frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.red)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                if r.id != searchResults.last?.id { Divider().padding(.leading, 46) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // 底部：当前选点 + 收藏 + 主控按钮
    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 当前选点
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mapState.displayName ?? "当前选点").font(.subheadline.weight(.semibold)).lineLimit(1)
                    coordinateRow(label: "GCJ-02(国内)", system: .gcj02)
                    coordinateRow(label: "WGS-84(国际)", system: .wgs84)
                }
                Spacer()
                // 帮助说明按钮
                Button {
                    if spoofState == .active {
                        activeTip = .activation
                    } else {
                        activeTip = .deactivation
                    }
                } label: {
                    Text(spoofState == .active ? "无法生效？" : "无法取消？")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                // 收藏按钮
                Button {
                    if favorites.selectedFavoriteID != nil {
                        favorites.select(nil)
                        return
                    }
                    saveCurrentSelectionAsFavorite()
                } label: {
                    Image(systemName: favorites.selectedFavoriteID != nil ? "star.fill" : "star")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background((favorites.selectedFavoriteID != nil ? Color.yellow : Color.gray).opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(favorites.selectedFavoriteID != nil ? .orange : .gray)
                .disabled(favoriteSaveTask != nil)
                .accessibilityLabel(favorites.selectedFavoriteID != nil ? "已收藏，点击取消收藏" : "收藏当前选点")
            }
            // 收藏
            if favorites.favorites.isEmpty {
                Text("搜索或点击地图选点后，保存为收藏。").font(.footnote).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(favorites.favorites) { f in favoriteChip(f) } }.padding(.vertical, 2)
                }
            }
            // 主控按钮（带动画）
            HStack(spacing: 10) {
                Button(action: handleMainButtonTap) {
                    HStack(spacing: 6) {
                        if spoofState == .verifying {
                            ProgressView().tint(.white)
                        }
                        Text(spoofState == .active && needsSwitchButton ? "关闭" : buttonTitle)
                            .font(.headline).lineLimit(1)
                    }
                    .frame(maxWidth: needsSwitchButton ? nil : .infinity)
                    .frame(minWidth: needsSwitchButton ? 56 : nil)
                    .padding(.vertical, 14)
                    .padding(.horizontal, needsSwitchButton ? 12 : 14)
                }
                .background(buttonColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
                .disabled(spoofState == .verifying)

                if needsSwitchButton {
                    Button {
                        beginLocationOperation()
                    } label: {
                        Label("切换到此处", systemImage: "arrow.triangle.swap")
                            .font(.body.weight(.medium)).lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12).padding(.horizontal, 16)
                    }
                    .background(.blue, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: needsSwitchButton)
            .padding(.top, 4)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }


    private var needsSwitchButton: Bool {
        guard spoofState == .active,
              let sLat = activeSpoofLat,
              let sLon = activeSpoofLon else { return false }
        return !currentSelectionFavorite.coordinatePair.matchesWGS84(
            latitude: sLat,
            longitude: sLon
        )
    }

    private var buttonTitle: String {
        if runtimeMode.mode == .thirdParty {
            switch spoofState {
            case .idle: return "同步到第三方代理"
            case .verifying: return "检测并同步中…"
            case .active: return "停止第三方虚拟定位"
            }
        }
        switch spoofState {
        case .idle: return "开始虚拟定位"
        case .verifying: return "验证环境中…"
        case .active: return "停止虚拟定位"
        }
    }

    private var buttonColor: Color {
        switch spoofState {
        case .idle: return .blue
        case .verifying: return .gray
        case .active: return .green
        }
    }

    private func handleMainButtonTap() {
        switch spoofState {
        case .idle:
            beginLocationOperation()
        case .active:
            stopSpoofing()
        case .verifying:
            break
        }
    }

    private func beginLocationOperation() {
        guard spoofState != .verifying, locationOperationTask == nil else { return }
        let wasActive = spoofState == .active
        locationOperationID &+= 1
        let operationID = locationOperationID
        let selectionRevision = mapState.selection.revision
        let target = currentSelectionFavorite
        spoofState = .verifying

        locationOperationTask = Task { @MainActor in
            if runtimeMode.mode == .thirdParty {
                do {
                    let response = try await thirdPartyProxy.save(target)
                    guard !Task.isCancelled,
                          operationID == locationOperationID,
                          runtimeMode.mode == .thirdParty else {
                        return
                    }
                    // The remote write has already succeeded. If the user moved
                    // the map meanwhile, keep this target active and let
                    // needsSwitchButton offer syncing the newer selection.
                    spoofState = .active
                    activeSpoofLat = response.latitude
                    activeSpoofLon = response.longitude
                    RuntimeLogger.info("APP", "定位", "第三方代理坐标同步成功", details: [
                        "当前客户端": thirdPartyClient.selectedClient.name,
                        "坐标标准": "WGS-84",
                        "客户端模式": "测试模式",
                        "选点期间发生变化": String(selectionRevision != mapState.selection.revision)
                    ])
                    presentSuccessfulOperationTip(.activation)
                    queueCommunityContributionPrompt(for: thirdPartyClient.selectedClient)
                } catch {
                    guard operationID == locationOperationID else { return }
                    // A failed replacement does not clear the coordinate that
                    // was already persisted inside the third-party client.
                    spoofState = wasActive ? .active : .idle
                    RuntimeLogger.error(
                        "APP",
                        "ThirdPartyProxy",
                        "同步坐标到第三方客户端失败",
                        error: error,
                        details: [
                            "当前客户端": thirdPartyClient.selectedClient.name,
                            "请求动作": "WLOC save",
                            "恢复状态": wasActive ? "保留原第三方坐标" : "保持未启用",
                            "处理建议": ThirdPartyProxyError.recoverySuggestion(for: error)
                        ]
                    )
                    setup.requestThirdPartySetup(message: error.localizedDescription)
                }
                if operationID == locationOperationID {
                    locationOperationTask = nil
                }
                return
            }

            let result = runtimeMode.mode == .builtInVPN
                ? await setup.runVPNVerificationTest()
                : await setup.runVerificationTest()
            guard !Task.isCancelled,
                  operationID == locationOperationID,
                  selectionRevision == mapState.selection.revision else {
                if operationID == locationOperationID {
                    spoofState = actions.virtualLocationEnabled ? .active : .idle
                    locationOperationTask = nil
                }
                return
            }

            if result.isSuccess {
                let applied = actions.applyVerified(target)
                spoofState = applied ? .active : .idle
                if applied {
                    activeSpoofLat = target.latitude
                    activeSpoofLon = target.longitude
                    lastSpoofDiagnosisSystem = nil
                    hasLoggedSpoofDiagnosis = false
                }
                RuntimeLogger.info("APP", "定位", "验证结果", details: [
                    "success": "true",
                    "applied": String(applied),
                    "spoofState": String(describing: spoofState)
                ])
                if applied {
                    presentSuccessfulOperationTip(.activation)
                }
            } else {
                spoofState = actions.virtualLocationEnabled ? .active : .idle
                RuntimeLogger.warning("APP", "定位", "验证失败", details: [
                    "result": result.id,
                    "spoofState": String(describing: spoofState)
                ])
                if result != .verificationInProgress,
                   result != .verificationSuperseded {
                    RuntimeLogger.warning("APP", "定位", "开启前检测失败，进入对应环境引导", details: [
                        "结果": result.id
                    ])
                    activeTip = nil
                    setup.applyVerificationResult(result)
                }
            }
            locationOperationTask = nil
        }
    }

    private func stopSpoofing() {
        locationOperationTask?.cancel()
        locationOperationTask = nil
        locationOperationID &+= 1
        if runtimeMode.mode == .thirdParty {
            spoofState = .verifying
            locationOperationTask = Task { @MainActor in
                do {
                    try await thirdPartyProxy.clear()
                    spoofState = .idle
                    activeSpoofLat = nil
                    activeSpoofLon = nil
                    presentSuccessfulOperationTip(.deactivation)
                } catch {
                    spoofState = .active
                    RuntimeLogger.error(
                        "APP",
                        "ThirdPartyProxy",
                        "清除第三方客户端坐标失败",
                        error: error,
                        details: [
                            "当前客户端": thirdPartyClient.selectedClient.name,
                            "请求动作": "WLOC clear",
                            "恢复状态": "保留已启用状态",
                            "处理建议": ThirdPartyProxyError.recoverySuggestion(for: error)
                        ]
                    )
                    setup.requestThirdPartySetup(message: error.localizedDescription)
                }
                locationOperationTask = nil
            }
            return
        }

        actions.clear()
        spoofState = .idle
        activeSpoofLat = nil
        activeSpoofLon = nil
        lastSpoofDiagnosisSystem = nil
        hasLoggedSpoofDiagnosis = false
        if runtimeMode.mode == .builtInVPN {
            BuiltInVPNManager.shared.disconnect()
        }
        presentSuccessfulOperationTip(.deactivation)
    }

    private func presentSuccessfulOperationTip(_ kind: VirtualLocationTipKind) {
        let count = tipPreferences.recordSuccessfulOperation(kind)
        let operationName = kind == .activation ? "开启" : "关闭"
        RuntimeLogger.info("APP", "提醒", "累计\(operationName)虚拟定位次数", details: [
            "次数": String(count),
            "运行模式": runtimeMode.mode.displayName,
            "可显示不再提醒": String(tipPreferences.canSuppress(kind))
        ])
        guard tipPreferences.shouldPresentAutomaticTip(kind) else { return }
        switch kind {
        case .activation:
            showEnableTip = true
        case .deactivation:
            showDisableTip = true
        }
    }

    private func queueCommunityContributionPrompt(for client: ThirdPartyProxyClient) {
        guard remoteConfiguration.requestsCommunityPrompt(for: client),
              communityPromptPreferences.shouldPresent() else {
            return
        }
        communityPromptPreferences.recordPresentation()
        if showEnableTip {
            pendingCommunityContributionClient = client
        } else {
            communityContributionClient = client
        }
    }

    private func openCommunityContributionPage() {
        githubDestination = SafariDestination(url: GitHubSubmission.communityContributionURL)
    }


    private func favoriteChip(_ f: FavoriteLocation) -> some View {
        HStack(spacing: 0) {
            Button { select(f) } label: {
                Label(f.name, systemImage: favorites.selectedFavoriteID == f.id ? "checkmark.circle.fill" : "mappin")
                    .lineLimit(1).padding(.leading, 10).padding(.vertical, 8).padding(.trailing, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Divider().frame(height: 22)
            Button {
                editingFavorite = f
                editName = f.name
            } label: {
                Image(systemName: "pencil").font(.caption2).frame(width: 32, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.primary.opacity(0.55))
            Divider().frame(height: 22)
            Button(role: .destructive) { favorites.delete(f) } label: {
                Image(systemName: "trash").font(.caption.weight(.semibold)).frame(width: 36, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.red)
        }
        .background((favorites.selectedFavoriteID == f.id ? Color.red.opacity(0.14) : Color.secondary.opacity(0.12)), in: Capsule())
        .overlay(Capsule().stroke(favorites.selectedFavoriteID == f.id ? Color.red.opacity(0.7) : Color.clear))
    }

    @MainActor
    private func openSettings(_ destination: SystemSettingsDestination) {
        SystemSettingsNavigator.open(destination) { fallbackHint in
            if let fallbackHint { manualHint = fallbackHint }
        }
    }


    private var currentSelectionFavorite: FavoriteLocation {
        FavoriteLocation(
            name: mapState.displayName ?? String(
                format: "%.4f, %.4f",
                mapState.selection.coordinate.latitude,
                mapState.selection.coordinate.longitude
            ),
            coordinatePair: .init(
                mapCoordinate: mapState.selection.coordinate,
                mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
            ),
            accuracy: 25
        )
    }

    private var currentSelectionPair: CoordinatePair {
        if let stored = LastCoordinateStore.load(),
           stored.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
            .isApproximatelyEqual(to: mapState.selection.coordinate) {
            return stored.coordinatePair
        }
        return CoordinatePair(
            mapCoordinate: mapState.selection.coordinate,
            mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
        )
    }

    private func coordinateRow(
        label: String,
        system: CoordinateConverter.MapCoordinateSystem
    ) -> some View {
        let coordinate = currentSelectionPair.coordinate(for: system)
        let text = String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(copiedCoordinateSystem == system ? .green : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .layoutPriority(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = text
            copiedCoordinateSystem = system
            RuntimeLogger.info("APP", "地图", "已复制坐标", details: [
                "坐标标准": system.diagnosticName
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedCoordinateSystem == system { copiedCoordinateSystem = nil }
            }
        }
        .overlay(alignment: .topTrailing) {
            if copiedCoordinateSystem == system {
                Text("已复制")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.green, in: Capsule())
                    .offset(y: -24)
            }
        }
    }

    private var testFavorite: FavoriteLocation { currentSelectionFavorite }

    private func startMapRuntimeOnce() {
        guard !mapRuntimeDidStart else { return }
        mapRuntimeDidStart = true
        let pair = LastCoordinateStore.load()?.coordinatePair
            ?? CoordinatePair(
                mapCoordinate: mapState.selection.coordinate,
                mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem
            )
        scheduleGeocode(pair: pair, revision: mapState.selection.revision)
    }

    @discardableResult
    private func reprojectMapSelection(for change: CoordinateConverter.MapCoordinateSystemChange) -> Bool {
        // Every current selection is persisted as a complete coordinate pair at
        // its input boundary. Replaying the matching stored representation
        // avoids a second GCJ/WGS conversion and its accumulated offset.
        guard let stored = LastCoordinateStore.load() else {
            RuntimeLogger.warning("APP", "坐标转换", "地图坐标标准切换时未找到当前选点缓存")
            return false
        }
        mapState.reprojectSelectionForMapCoordinateSystemChange(stored.coordinate(for: change.current))
        RuntimeLogger.info("APP", "坐标转换", "地图坐标标准切换后已使用缓存坐标对回显当前选点", details: [
            "from": change.previous.rawValue,
            "to": change.current.rawValue
        ])
        return true
    }

    private func applyRuntimeMapCoordinateSystemChange(
        _ change: CoordinateConverter.MapCoordinateSystemChange,
        reason: String
    ) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        searchRequestID &+= 1
        isSearching = false
        searchResults = []
        searchError = ""
        realtimeRequestTask?.cancel()
        realtimeRequestTask = nil
        realtimeRequestContext = nil
        mapState.clearRealtimeLocationForMapCoordinateSystemChange()
        let pinWasReprojected = reprojectMapSelection(for: change)
        if let stored = LastCoordinateStore.load() {
            scheduleGeocode(pair: stored.coordinatePair, revision: mapState.selection.revision)
        }
        RuntimeLogger.warning("APP", "坐标转换", "地图坐标类型已变化", details: [
            "触发原因": reason,
            "旧类型": change.previous.diagnosticName,
            "新类型": change.current.diagnosticName,
            "图钉已按新类型重设": String(pinWasReprojected),
            "蓝点缓存": "已清理",
            "搜索结果": "已清理",
            "异步地理编码": "已重置"
        ])
    }

    @discardableResult
    private func refreshRuntimeMapCoordinateSystem(reason: String) async -> Bool {
        let result = await CoordinateConverter.refreshRuntimeMapCoordinateSystem(reason: reason)
        guard !Task.isCancelled else { return false }
        switch result {
        case .changed(let change):
            applyRuntimeMapCoordinateSystemChange(change, reason: reason)
            return true
        case .unchanged:
            return true
        case .unavailable, .cancelled:
            return false
        }
    }

    private func scheduleBluePointMapCoordinateSystemRefresh() {
        guard mapCoordinateSystemRefreshTask == nil else {
            bluePointRefreshPending = true
            return
        }
        mapCoordinateSystemRefreshID &+= 1
        let refreshID = mapCoordinateSystemRefreshID
        mapCoordinateSystemRefreshTask = Task { @MainActor in
            defer {
                if refreshID == mapCoordinateSystemRefreshID {
                    let needsAnotherRefresh = bluePointRefreshPending && !Task.isCancelled
                    mapCoordinateSystemRefreshTask = nil
                    bluePointRefreshPending = false
                    if needsAnotherRefresh {
                        scheduleBluePointMapCoordinateSystemRefresh()
                    }
                }
            }
            // Coalesce the didUpdate/regionDidChange pair generated by one
            // native location sample without caching the probe result.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, refreshID == mapCoordinateSystemRefreshID else { return }
            var attempt = 0
            repeat {
                bluePointRefreshPending = false
                _ = await refreshRuntimeMapCoordinateSystem(reason: "MapKit蓝点新样本")
                attempt += 1
            } while !Task.isCancelled
                && refreshID == mapCoordinateSystemRefreshID
                && bluePointRefreshPending
                && attempt < 2
        }
    }

    private func awaitCoordinatedMapCoordinateSystemRefresh(reason: String) async {
        if let pendingRefresh = mapCoordinateSystemRefreshTask {
            await pendingRefresh.value
            return
        }
        mapCoordinateSystemRefreshID &+= 1
        let refreshID = mapCoordinateSystemRefreshID
        let task = Task { @MainActor in
            _ = await refreshRuntimeMapCoordinateSystem(reason: reason)
        }
        mapCoordinateSystemRefreshTask = task
        await task.value
        if refreshID == mapCoordinateSystemRefreshID {
            mapCoordinateSystemRefreshTask = nil
        }
    }

    private func saveCurrentSelectionAsFavorite() {
        guard favoriteSaveTask == nil else { return }
        let snapshot = currentSelectionFavorite
        // Preserve the pair created when this selection entered the map. If
        // the runtime probe changes type, replay its other stored field instead
        // of reinterpreting the old visible coordinate as the new type.
        let pair = currentSelectionPair
        let selectionRevision = mapState.selection.revision
        favoriteSaveTask = Task { @MainActor in
            defer { favoriteSaveTask = nil }
            await awaitCoordinatedMapCoordinateSystemRefresh(reason: "保存收藏")
            guard !Task.isCancelled else {
                return
            }
            guard mapState.selection.revision == selectionRevision else {
                RuntimeLogger.info("APP", "坐标转换", "取消保存收藏：检测期间当前选点已变化")
                return
            }
            RuntimeLogger.info("APP", "坐标转换", "保存当前选点为收藏", details: [
                "当前地图标准": CoordinateConverter.currentMapCoordinateSystem.diagnosticName,
                "持久化字段": "国际标准(WGS-84)+国内标准(GCJ-02)"
            ])
            let favorite = favorites.save(
                name: snapshot.name,
                coordinatePair: pair,
                accuracy: snapshot.accuracy
            )
            mapState.selectFavorite(
                pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
                id: favorite.id,
                name: favorite.name
            )
            LastCoordinateStore.save(coordinatePair: pair, zoomMeters: mapState.viewportMeters)
        }
    }

    private func registerWiFiChangeObserver() {
        guard runtimeMode.mode == .localWiFi else { return }
        guard wifiChangeObserverToken == nil else { return }
        wifiChangeObserverToken = net.observeWiFiChanges { [self] reason in
            handleWiFiChange(reason: reason)
        }
    }

    private func refreshThirdPartyState() {
        guard runtimeMode.mode == .thirdParty,
              locationOperationTask == nil else { return }
        locationOperationTask = Task { @MainActor in
            do {
                let response = try await thirdPartyProxy.query()
                if response.success,
                   let latitude = response.latitude,
                   let longitude = response.longitude {
                    activeSpoofLat = latitude
                    activeSpoofLon = longitude
                    spoofState = .active
                } else if response.error?.contains("无已保存") == true {
                    activeSpoofLat = nil
                    activeSpoofLon = nil
                    spoofState = .idle
                } else {
                    spoofState = .idle
                    RuntimeLogger.warning("APP", "ThirdPartyProxy", "第三方代理查询返回失败", details: [
                        "当前客户端": thirdPartyClient.selectedClient.name,
                        "请求动作": "WLOC query",
                        "错误": response.error ?? "未知错误"
                    ])
                    setup.requestThirdPartySetup(message: response.error ?? "第三方代理查询失败")
                }
            } catch {
                spoofState = .idle
                RuntimeLogger.warning("APP", "ThirdPartyProxy", "启动后第三方代理状态查询失败", details: [
                    "当前客户端": thirdPartyClient.selectedClient.name,
                    "请求动作": "WLOC query",
                    "连接状态": String(describing: thirdPartyProxy.connectionState),
                    "错误": error.localizedDescription
                ])
                setup.requestThirdPartySetup(message: error.localizedDescription)
            }
            locationOperationTask = nil
        }
    }

    private func handleWiFiChange(reason: WiFiChangeReason) {
        RuntimeLogger.info("APP", "WiFi", "检测到 Wi-Fi 网络变化", details: [
            "原因": reason.rawValue,
            "虚拟定位已开启": String(spoofState == .active)
        ])
        guard spoofState == .active else { return }
        if wifiVerificationTask != nil {
            RuntimeLogger.info("APP", "WiFi", "网络仍在变化，重新计算环境检测等待时间")
        }
        wifiVerificationTask?.cancel()
        let verificationID = UUID()
        wifiVerificationID = verificationID
        wifiVerificationTask = Task { @MainActor in
            defer {
                if wifiVerificationID == verificationID {
                    wifiVerificationTask = nil
                    wifiVerificationID = nil
                }
            }
            let stabilizationNanoseconds: UInt64 = 3_000_000_000
            RuntimeLogger.info("APP", "WiFi", "等待 Wi-Fi 连接稳定后检测", details: [
                "等待秒数": "3",
                "事件原因": reason.rawValue
            ])
            do {
                try await Task.sleep(nanoseconds: stabilizationNanoseconds)
            } catch {
                RuntimeLogger.debug("APP", "WiFi", "延时检测已被更新的网络事件取消")
                return
            }
            guard !Task.isCancelled, spoofState == .active else { return }
            guard net.isSatisfied, net.isWiFiEnabled else {
                RuntimeLogger.warning("APP", "WiFi", "稳定等待结束后仍未连接 Wi-Fi，提示检查代理", details: [
                    "网络可用": String(net.isSatisfied),
                    "Wi-Fi接口": String(net.isWiFiEnabled)
                ])
                activeTip = nil
                setup.requestSetup(message: "当前未连接可用的 Wi-Fi，请连接 Wi-Fi 后配置 127.0.0.1:8888 手动代理。")
                return
            }

            // A manual diagnostics request can occupy the verifier for its full
            // eight-second URL timeout. Wait long enough to run this check after
            // it finishes instead of silently dropping the Wi-Fi-change check.
            let maximumAttempts = 11
            for attempt in 1...maximumAttempts {
                RuntimeLogger.info("APP", "WiFi", "开始后台环境检测", details: [
                    "尝试": "\(attempt)/\(maximumAttempts)",
                    "SSID可读取": String(net.currentSSID != nil)
                ])
                let result = await setup.runVerificationTest()
                guard !Task.isCancelled, spoofState == .active else { return }
                if result == .verificationInProgress, attempt < maximumAttempts {
                    RuntimeLogger.info("APP", "WiFi", "已有环境检测运行，1 秒后重试", details: [
                        "尝试": "\(attempt)/\(maximumAttempts)"
                    ])
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        return
                    }
                    continue
                }

                RuntimeLogger.info("APP", "WiFi", "后台环境检测完成", details: [
                    "结果": result.id,
                    "success": String(result.isSuccess)
                ])
                if !result.isSuccess,
                   result != .verificationInProgress,
                   result != .verificationSuperseded {
                    activeTip = nil
                    setup.applyVerificationResult(result)
                } else if result == .verificationInProgress {
                    RuntimeLogger.warning("APP", "WiFi", "环境检测连续被占用，本次不重复弹窗")
                }
                return
            }
        }
    }

    private func requestRealtimeLocation() {
        guard realtimeButtonTask == nil else { return }
        realtimeButtonTask = Task { @MainActor in
            defer { realtimeButtonTask = nil }
            await awaitCoordinatedMapCoordinateSystemRefresh(reason: "点击实时定位")
            guard !Task.isCancelled else {
                return
            }
            performRealtimeLocationRequest()
        }
    }

    private func performRealtimeLocationRequest() {
        let intent = mapState.beginRealtimeIntent()
        RuntimeLogger.info("APP", "实时定位", "用户点击实时定位", details: [
            "intentID": String(intent.id),
            "选点revision": String(intent.selectionRevision),
            "当前地图标准": CoordinateConverter.currentMapCoordinateSystem.rawValue,
            "蓝点缓存存在": String(mapState.realtimeLocation != nil),
            "CLLocationManager请求中": String(realtime.isRequesting)
        ])
        // 蓝点存在就直接用，不限时（MKMapView 的 userLocation 只在位置变化时才更新）
        if let loc = mapState.realtimeLocation {
            RealtimeLocationTrace.log("实时定位按钮直接使用 MapKit 蓝点缓存", location: loc, details: [
                "intentID": String(intent.id),
                "来源": "MapLocationState.realtimeLocation"
            ])
            acceptRealtimeLocation(
                loc.coordinate,
                intent: intent,
                source: .mapKitBluePoint,
                sourceDescription: "MapKit蓝点缓存"
            )
            return
        }
        RuntimeLogger.info("APP", "实时定位", "MapKit 蓝点尚不可用，启动 CLLocationManager 兜底", details: [
            "intentID": String(intent.id)
        ])
        startRealtimeLocationRequest(
            source: "CLLocationManager",
            showFailureAlert: true,
            intent: intent
        )
    }

    private func handleNativeRealtimeLocation(_ location: CLLocation) {
        mapState.updateRealtimeLocation(location)
        logSpoofCoordinateDiagnosisIfNeeded(location)
        scheduleBluePointMapCoordinateSystemRefresh()
        guard let context = realtimeRequestContext else {
            return
        }

        RealtimeLocationTrace.log("主页收到待处理请求所需的 MapKit 蓝点回调", location: location, details: [
            "当前选点revision": String(mapState.selection.revision)
        ])

        // MKMapView's MKUserLocation is the visible blue point. When it arrives,
        // fulfill the pending intent from that exact sample and cancel the slower
        // CLLocationManager fallback so the camera and dot cannot disagree.
        realtimeRequestContext = nil
        realtimeRequestTask?.cancel()
        RuntimeLogger.info("APP", "实时定位", "MapKit 蓝点抢先完成请求，取消 CLLocationManager 兜底", details: [
            "intentID": String(context.intent.id),
            "原兜底来源": context.source
        ])
        acceptRealtimeLocation(
            location.coordinate,
            intent: context.intent,
            source: .mapKitBluePoint,
            sourceDescription: "蓝点(途中)→\(context.source)"
        )
    }

    private func logSpoofCoordinateDiagnosisIfNeeded(_ location: CLLocation) {
        guard spoofState == .active,
              let latitude = activeSpoofLat,
              let longitude = activeSpoofLon else { return }
        let targetPair = CoordinateConverter.coordinatePair(
            lat: latitude,
            lon: longitude,
            mapCoordinateSystem: .wgs84
        )
        let diagnosis = CoordinateConverter.diagnoseRepresentation(
            sample: location.coordinate,
            pair: targetPair,
            maximumDistance: max(1_000, location.horizontalAccuracy * 4),
            minimumSeparation: max(30, location.horizontalAccuracy)
        )
        let shouldLog = !hasLoggedSpoofDiagnosis
            || diagnosis.inferredSystem != lastSpoofDiagnosisSystem
        guard shouldLog else { return }
        hasLoggedSpoofDiagnosis = true
        lastSpoofDiagnosisSystem = diagnosis.inferredSystem
        RuntimeLogger.info("APP", "坐标转换", "虚拟定位开启后的 MapKit 蓝点标准判定", details: [
            "当前地图标准": CoordinateConverter.currentMapCoordinateSystem.diagnosticName,
            "WLOC目标标准": CoordinateConverter.MapCoordinateSystem.wgs84.diagnosticName,
            "蓝点回调更接近": diagnosis.inferredName,
            "蓝点距WGS目标米": String(format: "%.1f", diagnosis.distanceToWGS84),
            "蓝点距GCJ目标米": String(format: "%.1f", diagnosis.distanceToGCJ02),
            "日志策略": "每次开启首次或判定变化"
        ])
    }

    private func startRealtimeLocationRequest(
        source: String,
        showFailureAlert: Bool,
        intent suppliedIntent: RealtimeLocationIntent? = nil
    ) {
        let intent = suppliedIntent ?? mapState.beginRealtimeIntent()
        realtimeRequestContext = RealtimeLocationRequestContext(
            intent: intent,
            source: source,
            showFailureAlert: showFailureAlert
        )
        RuntimeLogger.info("APP", "实时定位", "登记实时定位请求上下文", details: [
            "intentID": String(intent.id),
            "选点revision": String(intent.selectionRevision),
            "来源": source,
            "失败时提示": String(showFailureAlert),
            "任务已存在": String(realtimeRequestTask != nil),
            "manager请求中": String(realtime.isRequesting)
        ])

        // A button tap during the startup request retargets that same in-flight
        // Core Location request to the newer intent instead of being ignored.
        guard realtimeRequestTask == nil, !realtime.isRequesting else {
            RuntimeLogger.info("APP", "实时定位", "复用进行中的 CLLocationManager 请求并更新意图上下文", details: [
                "intentID": String(intent.id)
            ])
            return
        }
        realtimeRequestTask = Task { @MainActor in
            defer {
                realtimeRequestTask = nil
                realtimeRequestContext = nil
            }
            guard let coordinate = await realtime.requestLocation() else {
                RuntimeLogger.warning("APP", "实时定位", "CLLocationManager 兜底未返回坐标", details: [
                    "授权状态rawValue": String(realtime.authorizationStatus.rawValue),
                    "任务已取消": String(Task.isCancelled),
                    "上下文存在": String(realtimeRequestContext != nil)
                ])
                guard let context = realtimeRequestContext,
                      context.showFailureAlert,
                      !Task.isCancelled,
                      mapState.selection.revision == context.intent.selectionRevision else { return }
                RuntimeLogger.info("APP", "地图", "定位失败 status=\(realtime.authorizationStatus.rawValue)")
                showLocationAlert = true
                return
            }
            RealtimeLocationTrace.coordinate("主页收到 CLLocationManager 兜底坐标", coordinate: coordinate, details: [
                "任务已取消": String(Task.isCancelled)
            ])
            guard !Task.isCancelled, let context = realtimeRequestContext else {
                RuntimeLogger.info("APP", "实时定位", "丢弃 CLLocationManager 结果：任务已取消或蓝点已抢先完成", details: [
                    "任务已取消": String(Task.isCancelled),
                    "上下文存在": String(realtimeRequestContext != nil)
                ])
                return
            }
            acceptRealtimeLocation(
                coordinate,
                intent: context.intent,
                source: .coreLocation,
                sourceDescription: context.source
            )
        }
    }

    private func acceptRealtimeLocation(
        _ coordinate: CLLocationCoordinate2D,
        intent: RealtimeLocationIntent,
        source: RealtimeCoordinateSource,
        sourceDescription: String
    ) {
        let currentViewport = mapState.viewportMeters
        let sourceCoordinateSystem = source.coordinateSystem
        let pair = CoordinateConverter.coordinatePair(
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            mapCoordinateSystem: sourceCoordinateSystem
        )
        let accepted = mapState.acceptRealtimeLocation(
            pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
            intent: intent
        )
        RuntimeLogger.info("APP", "实时定位", "实时定位坐标完成标准判断并提交到地图", details: [
            "来源": sourceDescription,
            "来源类型": source.diagnosticName,
            "输入坐标标准": sourceCoordinateSystem.diagnosticName,
            "intentID": String(intent.id),
            "intent选点revision": String(intent.selectionRevision),
            "当前选点revision": String(mapState.selection.revision),
            "App已确认地图标准": CoordinateConverter.currentMapCoordinateSystem.rawValue,
            "accepted": String(accepted),
            "显示坐标字段": CoordinateConverter.currentMapCoordinateSystem.rawValue,
            "持久化字段": "WGS-84+GCJ-02"
        ])
        RealtimeLocationTrace.coordinate("原始实时定位坐标", coordinate: coordinate, details: [
            "来源": sourceDescription,
            "输入坐标标准": sourceCoordinateSystem.diagnosticName
        ])
        RealtimeLocationTrace.coordinate("地图实际显示坐标", coordinate: pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem), details: [
            "地图标准": CoordinateConverter.currentMapCoordinateSystem.rawValue
        ])
        guard accepted else { return }
        // 用点击时的缩放级别居中，不改变缩放
        mapState.focusSelection(distanceMeters: currentViewport)
        // Persist both forms once from the explicitly typed input boundary.
        LastCoordinateStore.save(coordinatePair: pair, zoomMeters: currentViewport)
        favorites.selectMatching(coordinatePair: pair)
        scheduleGeocode(pair: pair, revision: mapState.selection.revision)
    }

    private func scheduleGeocode(pair: CoordinatePair, revision: UInt64) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        geocodeDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, mapState.selection.revision == revision else { return }
            reverseGeocode(pair, revision: revision)
        }
    }

    private func reverseGeocode(_ pair: CoordinatePair, revision: UInt64) {
        reverseGeocodeTask?.cancel()
        let wgsCoordinate = pair.wgs84.coordinate
        let mapCoordinate = pair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem)
        let location = CLLocation(latitude: wgsCoordinate.latitude, longitude: wgsCoordinate.longitude)
        reverseGeocodeTask = Task { @MainActor in
            let retryDelays: [UInt64] = [0, 800_000_000, 1_600_000_000]
            var lastError: Error?

            for (attempt, delay) in retryDelays.enumerated() {
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: delay) }
                    catch { return }
                }
                guard !Task.isCancelled, mapState.selection.revision == revision else { return }

                do {
                    // 并⾏获取：CLGeocoder（地址结构化） + MKLocalSearch（地图显⽰名称）
                    // MKLocalSearch 在无结果时抛错，不可与 CLGeocoder 共用 try await 导致互相影响
                    async let clPlacemarks = CLGeocoder().reverseGeocodeLocation(location)
                    let mkRequest = MKLocalSearch.Request()
                    mkRequest.region = MKCoordinateRegion(center: mapCoordinate, latitudinalMeters: 400, longitudinalMeters: 400)
                    let mkResponse = try? await MKLocalSearch(request: mkRequest).start()

                    let placemarks = try await clPlacemarks
                    guard !Task.isCancelled,
                          mapState.selection.revision == revision,
                          let placemark = placemarks.first else { return }

                    if mkResponse?.mapItems.first != nil {
                        RuntimeLogger.info("APP", "Geocode", "MKLocalSearch 返回地点结果")
                    }
                    let mapItemName = mkResponse?.mapItems.first?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let mapItemPOI = mkResponse?.mapItems.first?.placemark.areasOfInterest?.first
                    // 优先使⽤ MKLocalSearch 结果（与地图显⽰一致），CLGeocoder 作为 fallback
                    let poi = { () -> String? in
                        if let v = mapItemPOI?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
                        if let v = mapItemName?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
                        return placemark.areasOfInterest?.first ?? placemark.name
                    }()
                    let streetAddress = [placemark.thoroughfare, placemark.subThoroughfare]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    let descriptor = MapPlaceDescriptor(
                        pointOfInterest: poi,
                        streetAddress: streetAddress,
                        road: placemark.thoroughfare,
                        neighborhood: placemark.subLocality,
                        district: placemark.subLocality ?? placemark.subAdministrativeArea,
                        city: placemark.locality ?? placemark.subAdministrativeArea,
                        province: placemark.administrativeArea,
                        country: placemark.country
                    )
                    _ = mapState.acceptPlaceDescriptor(descriptor, selectionRevision: revision)
                    return
                } catch {
                    guard !Task.isCancelled, mapState.selection.revision == revision else { return }
                    lastError = error
                    let nsError = error as NSError
                    let isNetworkError = nsError.domain == kCLErrorDomain
                        && nsError.code == CLError.network.rawValue
                    guard isNetworkError, attempt < retryDelays.count - 1 else { break }
                    RuntimeLogger.info("APP", "Geocode", "反向地理编码网络失败，准备重试", details: [
                        "attempt": String(attempt + 1),
                        "revision": String(revision)
                    ])
                }
            }

            guard !Task.isCancelled,
                  mapState.selection.revision == revision,
                  let lastError else { return }
            RuntimeLogger.warning("APP", "Geocode", "反向地理编码失败", details: [
                "error": lastError.localizedDescription,
                "revision": String(revision)
            ])
        }
    }

    private func doSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }
        searchRequestID &+= 1
        let requestID = searchRequestID
        isSearching = true
        searchError = ""
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                guard requestID == searchRequestID else { return }
                isSearching = false
                if let error {
                    searchResults = []
                    searchError = error.localizedDescription
                    return
                }
                searchResults = (response?.mapItems ?? []).prefix(6).map { item in
                    let r = SearchLocationResult(
                        name: item.name ?? "未命名",
                        subtitle: [item.placemark.locality, item.placemark.subLocality, item.placemark.thoroughfare]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "),
                        coordinate: item.placemark.coordinate
                    )
                    RuntimeLogger.info("APP", "搜索", "获得搜索结果", details: [
                        "名称": r.name
                    ])
                    return r
                }
                if searchResults.isEmpty { searchError = "没有找到相关地点" }
            }
        }
    }

    private func selectSearchResult(_ result: SearchLocationResult) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        favorites.select(nil)
        mapState.selectSearchResult(result.coordinate, name: result.name)
        LastCoordinateStore.save(
            mapCoordinate: result.coordinate,
            mapCoordinateSystem: CoordinateConverter.currentMapCoordinateSystem,
            zoomMeters: mapState.viewportMeters
        )
        searchText = result.name
        searchResults = []
        searchError = ""
    }

    private func deleteSearchResult(_ result: SearchLocationResult) {
        searchResults.removeAll { $0.id == result.id }
    }

    private func select(_ favorite: FavoriteLocation) {
        geocodeDebounceTask?.cancel()
        reverseGeocodeTask?.cancel()
        favorites.select(favorite.id)
        RuntimeLogger.info("APP", "坐标转换", "点击收藏点并回显到地图", details: [
            "当前地图标准": CoordinateConverter.currentMapCoordinateSystem.diagnosticName,
            "地图取值字段": CoordinateConverter.currentMapCoordinateSystem == .gcj02 ? "coordinatePair.gcj02" : "coordinatePair.wgs84",
            "保存数据包含": "国际标准(WGS-84)+国内标准(GCJ-02)"
        ])
        mapState.selectFavorite(
            favorite.coordinatePair.coordinate(for: CoordinateConverter.currentMapCoordinateSystem),
            id: favorite.id,
            name: favorite.name
        )
        LastCoordinateStore.save(
            coordinatePair: favorite.coordinatePair,
            zoomMeters: mapState.viewportMeters
        )
    }

    private var enableTipSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ActivationTipContent(runtimeMode: runtimeMode.mode, dismiss: {})
                }.padding(16)
            }
            .navigationTitle("虚拟定位已开启").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    if tipPreferences.canSuppress(.activation) {
                        Button {
                            tipPreferences.suppress(.activation)
                            showEnableTip = false
                        } label: {
                            Label("不再提醒", systemImage: "bell.slash.fill")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button { showEnableTip = false } label: {
                            Text("知道了")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    } else {
                        Button { showEnableTip = false } label: {
                            Text("知道了")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    private var disableTipSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DeactivationTipContent(runtimeMode: runtimeMode.mode, dismiss: {})
                    if runtimeMode.mode == .localWiFi {
                        RemoveProxyTipContent(dismiss: {})
                    }
                }.padding(16)
            }
            .navigationTitle("虚拟定位已关闭").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    if tipPreferences.canSuppress(.deactivation) {
                        Button {
                            tipPreferences.suppress(.deactivation)
                            showDisableTip = false
                        } label: {
                            Label("不再提醒", systemImage: "bell.slash.fill")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        Button { showDisableTip = false } label: {
                            Text("知道了")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    } else {
                        Button { showDisableTip = false } label: {
                            Text("知道了")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }
}
