# Build

## Requirements

- macOS with Xcode and Command Line Tools
- Go 1.26 or newer（`Core/go.mod` 声明 1.26.3；旧版本工具链会在允许时自动下载）
- XcodeGen (`brew install xcodegen`)

## One-command build

```bash
./build.sh
```

该脚本会先检查 `xcrun`、`xcodebuild`、`xcodegen` 和 `go`，随后构建 iOS Go 静态库、重新生成 Xcode 工程、构建并输出未签名 IPA。

如需在未签名 IPA 已生成后额外运行 `PaopaoLocationSpoofer` 的 iOS Simulator 单元测试：

```bash
./build.sh --test
```

`--test` 默认使用名为 `iPhone 16` 的 Simulator。若本机没有该设备，请传入已安装设备的 destination：

```bash
SIMULATOR_DESTINATION='platform=iOS Simulator,name=<你的模拟器名称>' ./build.sh --test
```

Output:

```text
dist/PaopaoLocationSpoofer-unsigned.ipa
```

IPA 始终保持未签名。用 [Impactor](https://github.com/claration/Impactor) 签名安装即可。

## 内置 VPN 扩展

IPA 内的 `PlugIns/PaopaoVPNExtension.appex` 是内置 VPN 模式的 Network Extension（Packet Tunnel）。
它和主 App 链接同一份 `libwloccore.a`，在隧道内复用 Go 核心的 MITM 与 wloc 改写逻辑。

签名要求：

- 扩展需要 `com.apple.developer.networking.networkextension`（`packet-tunnel-provider`）权限；
  该权限只能由付费 Apple Developer 账号签发，免费个人账号签名的构建无法加载扩展。
- 自签安装时，为 App 应用 `Scripts/impactor-entitlements-app.plist`，为扩展应用
  `Scripts/impactor-entitlements-extension.plist`。
- 扩展与 App 共用 App Group `group.com.paopaolabs.location-spoofer` 与同一 keychain access group
  （CA 证书存储），签名时不要改动这两个值。

模拟器无法加载 Network Extension，内置 VPN 只能真机验证。

## 发布验收

1. `./build.sh` 通过并输出未签名 IPA
2. 用 Impactor 签名后安装到设备
3. 真机安装后，先配置 WiFi HTTP 代理 `127.0.0.1:8888`，再按检测结果完成 CA 下载、安装和信任
4. 环境检测通过后，选点开启虚拟定位
5. 打开 Apple 地图验证定位是否变为虚拟位置
6. 若失败，查看诊断页的日志信息
7. （内置 VPN）用付费账号签名并注入扩展权限后，选择内置 VPN 模式：信任 CA → 启用隧道 →
   状态栏出现 VPN 图标 → 选点开启虚拟定位 → 地图/天气定位变为虚拟位置；断开后恢复真实定位

## 发布版本

发布前先生成版本归档并提交：

```bash
./Scripts/generate-release-notes.sh v1.1.0
git add docs/releases/v1.1.0.md
git commit -m "docs: archive v1.1.0 release notes"
git tag v1.1.0
git push origin main v1.1.0
```

归档文件根据“上一个版本标签到当前提交”的 commit subject 生成。GitHub Actions 会校验归档存在，并将文件正文直接作为 GitHub Release 内容；不会发布文档链接或缺失说明的占位 Release。
