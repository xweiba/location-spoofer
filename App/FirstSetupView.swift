import SwiftUI
import UIKit

private struct SetupScreenshotPreview: Identifiable {
    let id = UUID()
    let image: UIImage
    let title: String
}

private struct CertificateDownloadDestination: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ThirdPartyConnectionTestFailure {
    let message: String
}

enum SetupStep: Int, CaseIterable {
    case mode
    case proxy
    case cert
    case thirdPartyClient
    case thirdPartyImport
    case vpn

    var title: String {
        switch self {
        case .mode: return "选择模式"
        case .proxy: return "配置 Wi-Fi 代理"
        case .cert: return "初始化 CA 证书"
        case .thirdPartyClient: return "选择客户端"
        case .thirdPartyImport: return "导入并检测"
        case .vpn: return "启用内置VPN"
        }
    }
}

struct FirstSetupView: View {
    @ObservedObject var setup: SetupCoordinator
    let onComplete: () -> Void

    @State private var step: SetupStep
    @State private var downloadedDone = false
    @State private var installedDone = false
    @State private var trustedDone = false
    @State private var result: VerificationResult?
    @State private var isVerifying = false
    @State private var isPreparingMode = false
    @State private var manualHint = ""
    @State private var setupActionError = ""
    @State private var showDiagnostics = false
    @StateObject private var diagnosticActions = LocationActionCoordinator()
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var vpnManager = BuiltInVPNManager.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject private var thirdPartyClient = ThirdPartyProxyClientStore.shared
    @ObservedObject private var motionSimulation = MotionSimulationStore.shared
    @State private var copiedSubscriptionURL = false
    @State private var copiedMITMHostname = false
    @State private var screenshotPreview: SetupScreenshotPreview?
    @State private var certificateDownloadDestination: CertificateDownloadDestination?
    @State private var thirdPartyTestFailure: ThirdPartyConnectionTestFailure?
    @State private var showThirdPartyRepairReason: Bool
    @State private var showsVerificationResult: Bool
    @State private var showsThirdPartyFailureLog: Bool

    init(setup: SetupCoordinator, onComplete: @escaping () -> Void) {
        self.setup = setup
        self.onComplete = onComplete
        _step = State(initialValue: setup.setupStep)
        _showThirdPartyRepairReason = State(
            initialValue: setup.setupStep == .thirdPartyImport && !setup.message.isEmpty
        )
        _showsVerificationResult = State(
            initialValue: [.proxy, .cert, .vpn].contains(setup.setupStep)
                && setup.lastVerificationResult != nil
        )
        _showsThirdPartyFailureLog = State(
            initialValue: setup.setupStep == .thirdPartyImport && !setup.message.isEmpty
        )
    }

    private var certificateStepsComplete: Bool { downloadedDone && installedDone && trustedDone }
    private var diagnosticFavorite: FavoriteLocation {
        FavoriteLocation(name: "诊断位置", latitude: 22.544577, longitude: 113.94114, accuracy: 25)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                progress
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch step {
                            case .mode: modeStep
                            case .proxy: proxyStep
                            case .cert: certificateStep
                            case .thirdPartyClient: thirdPartyClientStep
                            case .thirdPartyImport: thirdPartyImportStep
                            case .vpn: vpnStep
                            }
                            if let displayedVerificationResult { resultView(displayedVerificationResult) }
                        }
                        .padding(20)
                    }
                    .onChange(of: thirdPartyFailureLog) { failureLog in
                        guard step == .thirdPartyImport, failureLog != nil else { return }
                        DispatchQueue.main.async {
                            withAnimation {
                                scrollProxy.scrollTo("thirdPartyFailureLog", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: step) { _ in
                        showsVerificationResult = false
                        showsThirdPartyFailureLog = false
                    }
                }
                Divider()
                if step != .mode {
                    HStack(spacing: 12) {
                        Button {
                            returnToPreviousStep()
                        } label: {
                            Label("上一步", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isVerifying || thirdPartyProxy.isRequesting)
                        Spacer(minLength: 12)
                        primaryAction
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("开始使用")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showDiagnostics) {
                NavigationView {
                    RuntimeLogsView(
                        setup: setup,
                        actions: diagnosticActions,
                        testFavorite: diagnosticFavorite
                    )
                }
            }
            .sheet(item: $screenshotPreview) { preview in
                NavigationView {
                    ScrollView {
                        Image(uiImage: preview.image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding()
                    }
                    .navigationTitle(preview.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { screenshotPreview = nil }
                        }
                    }
                }
            }
            .sheet(item: $certificateDownloadDestination) { destination in
                SafariView(url: destination.url)
                    .ignoresSafeArea()
            }
            .alert("无法直接跳转", isPresented: Binding(
                get: { !manualHint.isEmpty },
                set: { if !$0 { manualHint = "" } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: { Text(manualHint) }
            .alert("操作失败", isPresented: Binding(
                get: { !setupActionError.isEmpty },
                set: { if !$0 { setupActionError = "" } }
            )) {
                Button("查看诊断日志") { showDiagnostics = true }
                Button("知道了", role: .cancel) {}
            } message: {
                Text(setupActionError)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(visibleSteps, id: \.rawValue) { value in
                HStack(spacing: 6) {
                    Circle()
                        .fill(value.rawValue <= step.rawValue ? Color.blue : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                    Text(value.title).font(.caption).foregroundStyle(.secondary)
                }
                if value != visibleSteps.last {
                    Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 28, height: 2)
                }
            }
        }
        .padding(.vertical, 16)
    }

    private var visibleSteps: [SetupStep] {
        switch step {
        case .mode:
            return [.mode]
        case .proxy:
            return [.mode, .proxy, .cert]
        case .cert:
            return runtimeMode.mode == .builtInVPN ? [.mode, .cert, .vpn] : [.mode, .proxy, .cert]
        case .vpn:
            return [.mode, .cert, .vpn]
        case .thirdPartyClient, .thirdPartyImport:
            return [.mode, .thirdPartyClient, .thirdPartyImport]
        }
    }

    private var displayedVerificationResult: VerificationResult? {
        guard showsVerificationResult else { return nil }
        return result ?? setup.lastVerificationResult
    }

    private var thirdPartyFailureLog: String? {
        guard showsThirdPartyFailureLog else { return nil }
        if let thirdPartyTestFailure {
            return thirdPartyTestFailure.message
        }
        guard !setup.message.isEmpty else { return nil }
        return """
        ======== 第三方代理运行检测 ========
        当前客户端：\(thirdPartyClient.selectedClient.name)
        触发来源：地图或设置中的第三方代理操作
        请求动作：WLOC 配置接口
        检测结果：失败
        错误详情：\(setup.message)
        处理建议：确认模块已启用，并检查 MITM、证书和代理/VPN 连接。
        """
    }

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择运行模式")
                .font(.title2.bold())
            Text("后续可在“设置 → 运行模式”中切换。多个模式不要同时拦截 WLOC 请求。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            modeCard(
                title: "APP模式",
                icon: "iphone.and.arrow.forward",
                badges: ["仅 Wi-Fi", "无外部依赖"],
                description: "App 在设备本地启动代理，通过当前 Wi-Fi 的手动 HTTP 代理改写定位响应。免费自签应用无法使用系统 VPN 的 Network Extension 能力，因此 APP模式不支持蜂窝网络，需要配置 Wi-Fi 代理并安装 App 生成的 CA。",
                tint: .blue
            ) {
                selectMode(.localWiFi)
            }
            .disabled(isPreparingMode)

            modeCard(
                title: "内置VPN模式",
                icon: "lock.shield",
                badges: ["Wi-Fi + 4G/5G", "一键启用"],
                description: "App 启用自带的系统 VPN，只捕获 Apple 定位服务（gs-loc.apple.com / gs-loc-cn.apple.com）的请求并改写定位响应，其余流量直接放行。无需配置 Wi-Fi 代理，也无需购买第三方 VPN。需要付费 Apple Developer 账号签名（免费签名的设备请选择 APP模式 或第三方代理模式）。",
                tint: .purple
            ) {
                selectMode(.builtInVPN)
            }
            .disabled(isPreparingMode)

            modeCard(
                title: "第三方代理模式",
                icon: "network.badge.shield.half.filled",
                badges: ["Wi-Fi + 4G/5G", "测试模式"],
                description: "App 负责选点，并通过 WLOC 配置接口查询和同步坐标；第三方代理客户端负责网络代理、模块拦截、MITM 和持久化。证书、VPN 与代理连接均由第三方客户端处理。",
                tint: .orange
            ) {
                selectMode(.thirdParty)
            }
            .disabled(isPreparingMode)

            if isPreparingMode {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在准备 APP模式本地服务…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func modeCard(
        title: String,
        icon: String,
        badges: [String],
        description: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
                HStack(spacing: 6) {
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tint.opacity(0.12), in: Capsule())
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }

    private var proxyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !setup.message.isEmpty {
                Label(setup.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(label: Label("先配置 Wi-Fi 系统代理", systemImage: "wifi")) {
                Text("在当前 Wi-Fi 的详情页，将「HTTP 代理」设为「手动」：服务器填 127.0.0.1，端口填 8888。配置后点击下方「完成」。检测会自动判断是 Wi-Fi 代理还是证书信任有问题。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            setupScreenshot(
                assetName: "AppModeWiFiProxy",
                title: "Wi-Fi 代理设置",
                caption: "1 选择手动，2 填写服务器 127.0.0.1，3 填写端口 8888。"
            )
            HStack(spacing: 12) {
                Button { UIPasteboard.general.string = "127.0.0.1:8888" } label: {
                    Label("复制地址", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { openSettings(.wifi) } label: {
                    Label("打开 Wi-Fi 设置", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var certificateStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            certificateCard(
                title: "第 1 步：下载证书",
                icon: "arrow.down.circle",
                description: "下载本机随机生成的 CA 根证书。私钥仅保存在此设备的钥匙串中，不会随证书文件导出。App 会弹出 Safari 下载页；出现配置描述文件下载提示时，选择「允许」。",
                actionTitle: "打开下载页",
                actionIcon: "arrow.down.circle.fill",
                complete: downloadedDone,
                action: {
                    Task {
                        if let url = await setup.proxy.prepareCertificateDownloadURL() {
                            certificateDownloadDestination = CertificateDownloadDestination(url: url)
                        } else {
                            setupActionError = setup.proxy.error ?? "无法准备证书下载页面，请查看诊断日志"
                        }
                    }
                },
                markComplete: { downloadedDone = true }
            )
            certificateCard(
                title: "第 2 步：安装证书",
                icon: "square.and.arrow.down",
                description: "下载完成后打开系统「设置」。如果顶部显示「已下载描述文件」，点进去安装；否则进入「通用 → VPN 与设备管理」，找到 Location Spoofer CA 并完成安装。",
                actionTitle: "去安装",
                actionIcon: "gearshape",
                complete: installedDone,
                action: { openSettings(.general) },
                markComplete: { installedDone = true }
            )
            setupScreenshot(
                assetName: "AppModeCertificateInstall",
                title: "安装证书",
                caption: "1 在「VPN 与设备管理」中打开 Location Spoofer CA 描述文件并完成安装。"
            )
            certificateCard(
                title: "第 3 步：信任证书",
                icon: "shield.checkered",
                description: "安装后进入「设置 → 通用 → 关于本机 → 证书信任设置」，找到 Location Spoofer CA 并开启完全信任。iOS 保留钥匙串数据时，重装 App 会继续复用同一证书。",
                actionTitle: "去信任",
                actionIcon: "shield.checkered",
                complete: trustedDone,
                action: { openSettings(.general) },
                markComplete: { trustedDone = true }
            )
            setupScreenshot(
                assetName: "AppModeCertificateTrust",
                title: "信任证书",
                caption: "1 在「证书信任设置」中为 Location Spoofer CA 开启完全信任。"
            )
        }
    }

    private var vpnStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !setup.message.isEmpty {
                Label(setup.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(label: Label("启用内置 VPN", systemImage: "lock.shield")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("点击下方「启用并验证」。首次启动时系统会弹窗询问是否允许添加 VPN 配置，请选择「允许」。该 VPN 只把 Apple 定位服务的两个域名接入隧道，其余流量不会经过。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Image(systemName: vpnStatusIcon)
                            .foregroundStyle(vpnManager.isConnected ? .green : .secondary)
                        Text(vpnStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            Text("内置 VPN 依赖 NetworkExtension 能力，只有付费 Apple Developer 账号签名（并为扩展注入 packet-tunnel-provider 权限）时可用。启动超时通常意味着签名缺少该权限。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var vpnStatusIcon: String {
        switch vpnManager.status {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reasserting: return "arrow.triangle.2.circlepath"
        case .disconnecting: return "arrow.down.circle"
        default: return "circle.dotted"
        }
    }

    private var vpnStatusText: String {
        switch vpnManager.status {
        case .connected: return "内置 VPN 已连接"
        case .connecting, .reasserting: return "内置 VPN 连接中…"
        case .disconnecting: return "内置 VPN 断开中…"
        default: return "内置 VPN 未连接"
        }
    }

    private var thirdPartyClientStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !setup.message.isEmpty {
                Label(setup.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            GroupBox(label: Label("选择第三方代理客户端", systemImage: "app.badge.checkmark")) {
                VStack(spacing: 0) {
                    ForEach(ThirdPartyProxyClient.allCases) { client in
                        Button {
                            thirdPartyClient.select(client)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(client.name).foregroundStyle(.primary)
                                    if let verificationText = client.verificationText {
                                        Text(verificationText)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Image(systemName: thirdPartyClient.selectedClient == client ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(thirdPartyClient.selectedClient == client ? .blue : .secondary)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if client != ThirdPartyProxyClient.allCases.last { Divider() }
                    }
                }
            }

            Text("除 Shadowrocket 外，当前客户端配置尚未完成真机验证，页面只提供模块导入入口和通用配置提醒。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            DisclosureGroup("第三方客户端适配说明") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("工作原理")
                        .font(.subheadline.bold())
                    Text("App 不连接远程坐标服务器，而是向 Apple 域名发起一个约定请求。第三方客户端需要在本机拦截该请求、保存 WGS-84 坐标并返回 JSON；定位模块再读取同一份数据，修改 Apple WLOC 响应。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("配置接口")
                        .font(.subheadline.bold())
                    Text(ThirdPartyProxyManager.configurationEndpoint.absoluteString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("""
                    查询：GET ?action=query
                    保存：GET ?lon=<经度>&lat=<纬度>&acc=<精度>
                    清除：GET ?action=clear
                    """)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    Text("返回格式")
                        .font(.subheadline.bold())
                    Text("""
                    成功：{"success":true,"longitude":113.0,"latitude":22.0,"accuracy":25}
                    失败：{"success":false,"error":"错误说明"}
                    """)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    Text("适配要求")
                        .font(.subheadline.bold())
                    Text("客户端需要支持请求脚本、持久化存储、HTTP 200 JSON 响应、Apple WLOC 响应脚本，以及 Apple 定位域名（gs-loc.apple.com、gsp-ssl.ls.apple.com、bluedot.is.autonavi.com 等）的 HTTPS 解密。保存接口和 WLOC 响应脚本必须读取同一份持久化数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
    }

    private var thirdPartyImportStep: some View {
        let client = thirdPartyClient.selectedClient
        return VStack(alignment: .leading, spacing: 16) {
            if showThirdPartyRepairReason {
                Label(
                    "检测到第三方代理连接异常，请检查模块、MITM 和代理连接后重新检测。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Label("第 1 步：导入 \(client.name) 模块", systemImage: "square.and.arrow.down")) {
                VStack(alignment: .leading, spacing: 12) {
                    instructionRow(1, "复制 \(client.name) 的模块订阅地址。")
                    Button {
                        UIPasteboard.general.string = client.subscriptionURL.absoluteString
                        copiedSubscriptionURL = true
                    } label: {
                        Label(copiedSubscriptionURL ? "已复制模块订阅地址" : "复制模块订阅地址", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    instructionRow(2, client == .shadowrocket
                        ? "打开 Shadowrocket，进入“配置 → 模块”。"
                        : "打开 \(client.name)。")
                    Button {
                        openThirdPartyClient(client)
                    } label: {
                        Label("打开 \(client.name)", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if client == .shadowrocket {
                        setupScreenshot(
                            assetName: "ShadowrocketConfigDetails",
                            title: "进入 Shadowrocket 配置",
                            caption: "1 点击「模块」进入模块列表，2 可打开当前本地配置详情。"
                        )
                    }

                    if client == .shadowrocket {
                        instructionRow(3, "点击右上角“+”，粘贴模块订阅地址并导入，然后确认模块已启用。")
                        setupScreenshot(
                            assetName: "ShadowrocketModuleImport",
                            title: "导入 Shadowrocket 模块",
                            caption: "1 点击右上角加号导入模块，2 确认模块已启用。"
                        )
                    } else {
                        instructionRow(3, "在 \(client.name) 中导入刚才复制的模块订阅地址。")
                    }
                }
            }

            if client == .shadowrocket {
                shadowrocketHTTPSDecryptionGuide
            } else {
                GroupBox(label: Label("第 2 步：完成 \(client.name) 配置", systemImage: "slider.horizontal.3")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("请在 \(client.name) 中完成相应配置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("配置时请复制下方全部解密域名（含 gsp-ssl.ls.apple.com、bluedot.is.autonavi.com）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        mitmHostnameCopyButton
                    }
                }
            }

            if let thirdPartyFailureLog {
                testResultView(
                    success: false,
                    title: "接口连接失败",
                    log: thirdPartyFailureLog
                )
                .id("thirdPartyFailureLog")
            }
        }
    }

    private var shadowrocketHTTPSDecryptionGuide: some View {
        GroupBox(label: Label("第 2 步：配置 HTTPS 解密", systemImage: "lock.open")) {
            VStack(alignment: .leading, spacing: 12) {
                instructionRow(1, "进入“配置 → 本地文件”，找到带黄点的配置，点击右侧 i 图标。")
                instructionRow(2, "进入“HTTPS 解密”，开启解密开关。")
                instructionRow(3, "在域名列表中添加下方复制的全部解密域名。")
                setupScreenshot(
                    assetName: "ShadowrocketHTTPSDecryption",
                    title: "配置 HTTPS 解密",
                    caption: "1 开启 HTTPS 解密，2 添加复制的全部解密域名，3 打开证书设置。"
                )

                mitmHostnameCopyButton

                instructionRow(4, "按 Shadowrocket 提示生成并完成证书授权。")
                setupScreenshot(
                    assetName: "ShadowrocketHTTPSCA",
                    title: "授权 Shadowrocket 证书",
                    caption: "1 打开 Shadowrocket 证书项并按提示安装、授权。"
                )
                instructionRow(5, "返回 HTTPS 解密页面，点击右上角勾号保存，然后开启代理。")

                Button {
                    openThirdPartyClient(.shadowrocket)
                } label: {
                    Label("打开 Shadowrocket 继续配置", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("App 只能唤起 Shadowrocket，无法通过公开接口直接跳转到“模块”或“HTTPS 解密”页面。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mitmHostnameCopyButton: some View {
        Button {
            UIPasteboard.general.string = ThirdPartyProxyManager.interceptionHostnamesText
            copiedMITMHostname = true
        } label: {
            Label(
                copiedMITMHostname ? "已复制解密域名" : "复制解密域名",
                systemImage: "doc.on.doc"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private func instructionRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue, in: Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func setupScreenshot(
        assetName: String,
        title: String,
        caption: String
    ) -> some View {
        if let image = UIImage(named: assetName) {
            Button {
                screenshotPreview = SetupScreenshotPreview(
                    image: image,
                    title: title
                )
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text(caption)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                }
                .padding(8)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)：\(caption)")
            .accessibilityHint("轻点查看大图")
        }
    }

    private func openThirdPartyClient(_ client: ThirdPartyProxyClient) {
        guard let url = client.launchURL else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            Task { @MainActor in
                manualHint = "无法打开 \(client.name)，请确认客户端已安装后手动打开。"
            }
        }
    }

    private func returnToPreviousStep() {
        result = nil
        setupActionError = ""
        switch step {
        case .mode:
            break
        case .proxy, .thirdPartyClient:
            step = .mode
        case .cert:
            step = runtimeMode.mode == .builtInVPN ? .mode : .proxy
        case .thirdPartyImport:
            thirdPartyTestFailure = nil
            step = .thirdPartyClient
        case .vpn:
            step = .cert
        }
    }

    private func certificateCard(
        title: String,
        icon: String,
        description: String,
        actionTitle: String,
        actionIcon: String,
        complete: Bool,
        action: @escaping () -> Void,
        markComplete: @escaping () -> Void
    ) -> some View {
        GroupBox(label: Label(title, systemImage: icon)) {
            VStack(alignment: .leading, spacing: 12) {
                Color.clear.frame(height: 0).padding(.top, 2)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button(action: action) {
                        Label(actionTitle, systemImage: actionIcon).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    Button(action: markComplete) {
                        Label(
                            complete ? "已完成 ✓" : "已完成",
                            systemImage: complete ? "checkmark.circle.fill" : "circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(complete ? .green : .secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func resultView(_ result: VerificationResult) -> some View {
        let success = result.isSuccess
        testResultView(
            success: success,
            title: success ? "环境检测通过" : failureSummary(result),
            log: setup.testLog
        )
    }

    private func testResultView(success: Bool, title: String, log: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
                .font(.subheadline.weight(.semibold))
            if !success {
                Text(log).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(8)
                Button {
                    showDiagnostics = true
                } label: {
                    Label("查看诊断日志", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background((success ? Color.green : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if step == .mode {
            EmptyView()
        } else if step == .proxy {
            Button {
                verifyAfterProxyConfirmation()
            } label: {
                actionLabel("完成")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying)
        } else if step == .cert {
            Button {
                verifyAfterCertificateConfirmation()
            } label: {
                actionLabel("完成")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!certificateStepsComplete || isVerifying)
        } else if step == .thirdPartyClient {
            Button {
                step = .thirdPartyImport
            } label: {
                actionLabel("完成")
            }
                .buttonStyle(.borderedProminent)
        } else if step == .vpn {
            Button {
                enableAndVerifyVPN()
            } label: {
                actionLabel("启用并验证")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying)
        } else {
            Button {
                verifyThirdPartyConnection()
            } label: {
                actionLabel("完成")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying || thirdPartyProxy.isRequesting)
        }
    }

    private func selectMode(_ mode: ProxyRuntimeMode) {
        guard !isPreparingMode else { return }
        runtimeMode.setMode(mode)
        result = nil
        switch mode {
        case .localWiFi:
            isPreparingMode = true
            Task { @MainActor in
                await setup.prepareLocalServices()
                isPreparingMode = false
                step = .proxy
            }
        case .thirdParty:
            setup.proxy.stop()
            BackgroundKeepAlive.shared.stop()
            step = .thirdPartyClient
        case .builtInVPN:
            setup.proxy.stop()
            BackgroundKeepAlive.shared.stop()
            isPreparingMode = true
            Task { @MainActor in
                await setup.prepareVPNServices()
                isPreparingMode = false
                step = .cert
            }
        }
    }

    private func verifyThirdPartyConnection() {
        guard !isVerifying else { return }
        let client = thirdPartyClient.selectedClient
        let startedAt = Date()
        isVerifying = true
        result = nil
        thirdPartyTestFailure = nil
        showsThirdPartyFailureLog = false
        setup.message = ""
        RuntimeLogger.info("APP", "ThirdPartyProxy", "开始第三方代理连接检测", details: [
            "当前客户端": client.name,
            "请求动作": "WLOC query",
            "检查范围": "模块拦截、MITM、代理/VPN连接"
        ])
        Task { @MainActor in
            defer { isVerifying = false }
            do {
                let response = try await thirdPartyProxy.validateConnection()
                let advancedFeaturesAvailable = await thirdPartyProxy.refreshAdvancedFeatureAvailability()
                if !advancedFeaturesAvailable {
                    motionSimulation.setEnabled(false)
                }
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                RuntimeLogger.info("APP", "ThirdPartyProxy", "第三方代理连接检测通过", details: [
                    "当前客户端": client.name,
                    "请求动作": "WLOC query",
                    "连接状态": response.latitude == nil || response.longitude == nil ? "已连接，无保存坐标" : "已连接，有保存坐标",
                    "运动状态模拟": advancedFeaturesAvailable ? "支持" : "不支持，已关闭",
                    "耗时毫秒": String(elapsedMilliseconds)
                ])
                onComplete()
            } catch {
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                let connectionState = thirdPartyConnectionStateDescription
                let errorType = String(describing: type(of: error))
                RuntimeLogger.error(
                    "APP",
                    "ThirdPartyProxy",
                    "第三方代理连接检测失败",
                    error: error,
                    details: [
                        "当前客户端": client.name,
                        "请求动作": "WLOC query",
                        "连接状态": connectionState,
                        "耗时毫秒": String(elapsedMilliseconds),
                        "错误类型": errorType,
                        "处理建议": ThirdPartyProxyError.recoverySuggestion(for: error)
                    ]
                )
                thirdPartyTestFailure = ThirdPartyConnectionTestFailure(
                    message: """
                    ======== 第三方代理连接检测 ========
                    当前客户端：\(client.name)
                    配置接口：/wloc-settings/save
                    请求动作：WLOC query
                    检查范围：模块拦截、MITM、证书、代理/VPN 连接
                    连接状态：\(connectionState)
                    检测结果：失败
                    耗时：\(elapsedMilliseconds) ms
                    错误类型：\(errorType)
                    错误详情：\(error.localizedDescription)
                    处理建议：\(ThirdPartyProxyError.recoverySuggestion(for: error))。
                    """
                )
                showsThirdPartyFailureLog = true
            }
        }
    }

    private var thirdPartyConnectionStateDescription: String {
        switch thirdPartyProxy.connectionState {
        case .unknown:
            return "未检测"
        case .connected(let active):
            return active ? "已连接，有保存坐标" : "已连接，无保存坐标"
        case .failed(let message):
            return "连接失败（\(message)）"
        }
    }

    private func actionLabel(_ title: String) -> some View {
        HStack {
            if isVerifying { ProgressView().tint(.white).controlSize(.small) }
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }

    private func verifyAfterProxyConfirmation() {
        runVerification { result in
            if result.isSuccess {
                onComplete()
            } else if result == .certNotTrusted {
                step = .cert
            } else {
                step = .proxy
            }
        }
    }

    private func verifyAfterCertificateConfirmation() {
        if runtimeMode.mode == .builtInVPN {
            result = nil
            step = .vpn
            return
        }
        runVerification { result in
            if result.isSuccess {
                onComplete()
            } else if result != .certNotTrusted {
                step = .proxy
            }
        }
    }

    private func enableAndVerifyVPN() {
        guard !isVerifying else { return }
        isVerifying = true
        result = nil
        showsVerificationResult = false
        Task {
            let verification = await setup.runVPNVerificationTest()
            setup.applyVerificationResult(verification)
            result = verification
            showsVerificationResult = true
            isVerifying = false
            if verification.isSuccess {
                onComplete()
            }
        }
    }

    private func runVerification(completion: @escaping (VerificationResult) -> Void) {
        guard !isVerifying else { return }
        isVerifying = true
        result = nil
        showsVerificationResult = false
        Task {
            let verification = await setup.runVerificationTest()
            setup.applyVerificationResult(verification)
            guard !Task.isCancelled else { return }
            result = verification
            showsVerificationResult = true
            isVerifying = false
            completion(verification)
        }
    }

    private func failureSummary(_ result: VerificationResult) -> String {
        switch result {
        case .certNotTrusted: return "证书尚未安装或信任"
        case .wifiProxyNotConfigured: return "Wi-Fi 代理未正确设置"
        case .builtInVPNNotActive: return "内置 VPN 未能拦截验证请求"
        case .proxyNotRunning: return "本地代理未能启动"
        case .verificationInProgress: return "检测仍在进行"
        case .verificationSuperseded: return "检测结果已过期"
        case .coordinateWriteFailed: return "坐标写入失败"
        case .patchFailed: return "定位改写检测失败"
        case .success: return "环境检测通过"
        }
    }

    @MainActor
    private func openSettings(_ destination: SystemSettingsDestination) {
        SystemSettingsNavigator.open(destination) { fallbackHint in
            if let fallbackHint { manualHint = fallbackHint }
        }
    }
}
