import SwiftUI

struct BugReportView: View {
    @ObservedObject var setup: SetupCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var isReproducible = true
    @State private var isRunning = false
    @State private var showCopiedAlert = false
    @State private var githubDestination: SafariDestination?
    @ObservedObject private var runtimeMode = ProxyRuntimeModeStore.shared
    @ObservedObject private var thirdPartyProxy = ThirdPartyProxyManager.shared
    @ObservedObject private var thirdPartyClient = ThirdPartyProxyClientStore.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 说明
                    Text("遇到问题时，在这里生成 Bug 报告。系统会运行一次诊断测试，并将完整报告复制到剪切板。跳转到 GitHub 后，请粘贴到“App 生成的诊断报告”字段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // 可复现环境
                    Toggle(isOn: $isReproducible) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("可复现环境").font(.subheadline.weight(.medium))
                            Text("当前设备上问题稳定复现，非偶发性。").font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // 问题描述
                    VStack(alignment: .leading, spacing: 6) {
                        Text("问题描述").font(.subheadline.weight(.medium))
                        TextEditor(text: $description)
                            .font(.caption)
                            .frame(minHeight: 120)
                            .padding(6)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(16)
            }

            Divider()
            // 底部按钮
            VStack(spacing: 8) {
                Button {
                    generateReport()
                } label: {
                    HStack {
                        if isRunning {
                            ProgressView().tint(.white)
                        }
                        (isRunning ? Text("正在生成报告…") : Text("生成 Bug 报告"))
                            .font(.body.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(isRunning || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .navigationTitle("报告 Bug")
        .navigationBarTitleDisplayMode(.inline)
        .alert("已生成", isPresented: $showCopiedAlert) {
            Button("打开 GitHub 表单") {
                githubDestination = SafariDestination(url: GitHubSubmission.bugReportURL)
            }
            Button("稍后再说", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("Bug 报告已复制到剪切板。请在 GitHub 表单的“App 生成的诊断报告”字段中粘贴并提交。")
        }
        .sheet(item: $githubDestination) { destination in
            SafariView(url: destination.url)
                .ignoresSafeArea()
        }
    }

    private func generateReport() {
        isRunning = true
        Task {
            let testLog: String
            if runtimeMode.mode == .thirdParty {
                do {
                    let response = try await thirdPartyProxy.query()
                    let active = response.success && response.latitude != nil && response.longitude != nil
                    let savedCoordinate = active ? AppLocalization.string("是") : AppLocalization.string("否")
                    testLog = AppLocalization.string("第三方代理测试模式：模块连接成功；已保存坐标=\(savedCoordinate)")
                } catch {
                    testLog = AppLocalization.string("第三方代理测试模式：模块连接失败；\(error.localizedDescription)")
                }
            } else {
                _ = await setup.runVerificationTest()
                testLog = setup.testLog
            }

            // 获取版本信息
            let appVersion: String = {
                let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                return "\(v) (\(b))"
            }()
            let systemVersion = UIDevice.current.systemVersion

            // 拼接报告
            let report = bugReport(
                appVersion: appVersion,
                systemVersion: systemVersion,
                testLog: testLog
            )

            // 复制到剪切板
            UIPasteboard.general.string = report
            isRunning = false

            // 弹窗
            showCopiedAlert = true
        }
    }

    private func bugReport(appVersion: String, systemVersion: String, testLog: String) -> String {
        let client = runtimeMode.mode == .thirdParty
            ? thirdPartyClient.selectedClient.name
            : AppLocalization.string("不适用")
        let reproducible = isReproducible ? AppLocalization.string("是") : AppLocalization.string("否")
        let diagnostics = testLog.isEmpty ? AppLocalization.string("（无诊断数据）") : testLog
        return """
        ### \(AppLocalization.string("环境信息"))
        \(AppLocalization.string("App 版本")): \(appVersion)
        \(AppLocalization.string("系统版本")): iOS \(systemVersion)
        \(AppLocalization.string("运行模式")): \(runtimeMode.mode.displayName)
        \(AppLocalization.string("第三方客户端")): \(client)
        \(AppLocalization.string("可复现环境")): \(reproducible)

        ### \(AppLocalization.string("问题描述"))
        \(description.trimmingCharacters(in: .whitespacesAndNewlines))

        ### \(AppLocalization.string("诊断日志"))
        ```
        \(diagnostics)
        ```
        """
    }
}
