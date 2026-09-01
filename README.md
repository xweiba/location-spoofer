<div align="center">

# 📍 Location Spoofer

### iOS Location Service Research & Testing Framework

一个用于 **iOS 定位服务研究、软件开发测试和 QA 验证** 的开源项目。

项目通过本机代理或第三方代理客户端，对 Apple 定位服务的指定响应进行测试环境模拟，帮助开发者验证应用在
不同地理位置和定位场景下的行为。

[![iOS 15+](https://img.shields.io/badge/iOS-15%2B-111111?logo=apple)](project.yml)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138)](project.yml)
[![Go 1.26+](https://img.shields.io/badge/Go-1.26%2B-00ADD8?logo=go)](Core/go.mod)
[![Version](https://img.shields.io/badge/version-v1.0.5-2563EB)](docs/CHANGELOG.md)

[功能概览](#功能概览) ·
[工作原理](#工作原理) ·
[快速开始](#快速开始) ·
[构建项目](#构建项目) ·
[English](README.en.md)

</div>

> [!IMPORTANT]
> 本项目用于学习研究、自有设备测试、软件开发和 QA 验证。
>
> 请仅在你拥有或获得授权的设备、网络和软件环境中使用，并遵守当地法律法规、网络管理规定以及相关服务条
> 款。
>
> 本项目不保证兼容所有 iOS 版本或第三方应用，也不承诺绕过第三方应用的安全策略、业务限制或服务规则。

## 项目定位

Location Spoofer 是一个面向 iOS 定位服务行为研究和开发测试的工具。

它提供：

- 原生地图选点和位置场景切换；
- Apple 定位服务响应的测试环境模拟；
- 本地代理、内置 VPN 和第三方代理三种运行模式；
- 坐标标准识别与 WGS-84 / GCJ-02 双坐标管理；
- 环境检测、运行日志和问题诊断；
- 收藏位置和上次地图状态恢复。

项目不修改目标 App 的源代码，也不提供远程控制或数据采集服务。

## 功能概览

- **原生地图交互**
    - 使用 MapKit 显示地图和系统蓝点；
    - 支持搜索、点击选点、拖动地图中心和缩放；
    - 支持收藏位置和恢复上次选点；
    - 当前选点同时显示国内坐标和国际坐标，可分别复制。

- **定位服务响应模拟**
    - 通过代理层处理指定的 Apple 定位服务请求；
    - 在测试环境中返回选定的坐标数据；
    - 不需要修改目标 App 代码。

- **三种运行模式**
    - APP 模式：在设备内运行 Go 代理，仅支持当前 Wi-Fi 网络；
    - 内置 VPN 模式：App 自带系统 VPN，只捕获 Apple 定位服务域名，Wi-Fi 与蜂窝均可用；
    - 第三方代理模式：通过支持的代理客户端覆盖 Wi-Fi、4G 或 5G，具体能力取决于客户端。

- **环境检测**
    - APP 模式检测本地代理、证书信任和请求链路；
    - 内置 VPN 模式检测隧道连接、证书信任和拦截链路；
    - 第三方代理模式检测 WLOC 配置接口和模块响应；
    - 失败时提供对应的配置或诊断入口。

- **开发调试**
    - 运行日志；
    - 日志复制和清理；
    - 坐标标准变化记录；
    - 脱敏问题报告生成。

## 工作原理

### APP 模式

APP 模式在设备内运行本地 Go 代理，并通过当前 Wi-Fi 的手动 HTTP 代理让指定请求经过本地代理。

```text
iOS 定位请求
      │
      │ 当前 Wi-Fi 手动 HTTP 代理
      ▼
设备内 wloccore Go 代理
      │
      │ 处理指定 Apple 定位服务请求
      ▼
Apple 定位服务响应
      │
      │ 测试坐标响应
      ▼
系统和应用读取定位结果
```

APP 模式：

- 不创建 Network Extension；
- 不显示或占用系统 VPN；
- 只覆盖当前 Wi-Fi 网络；
- 需要配置当前 Wi-Fi 的手动 HTTP 代理；
- 需要安装并信任 App 生成的本机 CA；
- 代理只处理项目定义的 Apple 定位服务和环境验证请求，不是通用网络抓包工具。

### 内置 VPN 模式

内置 VPN 模式在设备内运行一个 Network Extension（Packet Tunnel）。它不把全部流量接入隧道，而是只把
`gs-loc.apple.com` 与 `gs-loc-cn.apple.com` 两个域名的地址加入隧道路由。

```text
iOS 定位请求
      │
      │ 仅 gs-loc 域名的隧道路由
      ▼
内置 VPN 扩展（Network Extension）
      │
      │ 设备内 wloccore Go 代理（MITM + 改写）
      ▼
Apple 定位服务响应
      │
      │ 测试坐标响应
      ▼
系统和应用读取定位结果
```

内置 VPN 模式：

- 使用 App 自带的系统 VPN，首次启用需要允许系统添加 VPN 配置；
- 只覆盖两个 Apple 定位服务域名，其余流量不经过隧道；
- Wi-Fi 与蜂窝网络均可用；
- 需要安装并信任 App 生成的本机 CA（与 APP 模式共用同一证书）；
- 需要付费 Apple Developer 账号签名并注入 `packet-tunnel-provider` 权限（免费个人账号无法签发
  Network Extension 权限）。

### 第三方代理模式

第三方代理模式不启动 App 内置 Go 代理，也不使用 App 生成的 CA。

```text
地图选点
  │
  │ WGS-84 坐标
  ▼
WLOC 配置接口
  │
  ▼
第三方代理客户端保存配置
  │
  ▼
第三方代理客户端处理定位服务请求
```

在该模式下：

- App 负责地图选点、收藏、坐标同步和清除；
- 第三方客户端负责代理/VPN、MITM、证书和规则执行；
- 坐标持久化由第三方客户端负责；
- 是否支持 Wi-Fi、4G 或 5G 取决于客户端；
- App 关闭后，第三方客户端中的配置可能继续生效。

#### 配置接口与客户端适配

App 不会把坐标上传到项目服务器。它会发起以下 GET 请求，第三方客户端必须在设备本地拦截：

```text
https://gs-loc.apple.com/wloc-settings/save
```

| 操作 | 查询参数 | 用途 |
|---|---|---|
| 查询 | `action=query` | 检查模块是否连接，并读取当前保存的坐标 |
| 保存 | `lon=<WGS-84 经度>&lat=<WGS-84 纬度>&acc=<精度>` | 保存当前选点 |
| 清除 | `action=clear` | 删除已保存的测试坐标 |

拦截脚本必须返回 HTTP 200 和 JSON：

```json
{
  "success": true,
  "longitude": 113.0,
  "latitude": 22.0,
  "accuracy": 25
}
```

失败时返回：

```json
{
  "success": false,
  "error": "错误说明"
}
```

查询时没有已保存坐标，可以返回 `{"success":false,"error":"无已保存的坐标"}`。App 会把它识别为
“模块已连接，但虚拟定位未开启”。保存成功时，响应中的经纬度必须与请求中的 WGS-84 坐标一致。

要适配新的第三方客户端，需要：

1. 为 `gs-loc.apple.com/wloc-settings/save` 添加 HTTP 请求脚本，解析上述参数并返回约定 JSON；
2. 使用客户端的持久化存储保存坐标、精度和可选状态；
3. 为 `gs-loc.apple.com` 和 `gs-loc-cn.apple.com` 配置 HTTPS 解密；
4. 拦截 `gs-loc(-cn).apple.com/clls/wloc` 响应，读取同一份持久化数据并修改 WLOC 响应；
5. 提供可订阅的模块文件，并确认查询、保存、清除和定位恢复都能在真机完成。

App 只验证配置接口的 HTTP 状态、JSON 格式和坐标回读，不管理第三方客户端的证书、MITM、VPN 或代理状态。

不要同时启用 APP 模式代理和第三方代理模式，避免两个代理链路互相干扰。

## 运行模式

### APP 模式

适用于：

- 只使用 Wi-Fi 的设备测试；
- 不依赖第三方代理客户端的本地验证；
- 需要在 App 内完成代理、证书和环境检测的场景。

使用条件：

- iOS 设备；
- 当前 Wi-Fi 支持手动 HTTP 代理；
- 安装并信任本机 CA；
- 在 App 内完成代理配置和环境检测。

### 内置 VPN 模式

适用于：

- 需要同时覆盖 Wi-Fi 与蜂窝网络，又不想购买或配置第三方代理客户端；
- 希望免去手工配置 Wi-Fi 代理、一键启用虚拟定位的场景。

使用条件：

- 付费 Apple Developer 账号（免费个人账号无法签发 Network Extension 权限）；
- 签名时为扩展注入 `packet-tunnel-provider` 权限（见下方自签说明）；
- 安装并信任本机 CA；
- 首次启用时允许系统添加 VPN 配置。

启用后状态栏会显示 VPN 图标；该隧道只包含两个定位服务域名的路由，其他应用流量不经过隧道。

### 第三方代理模式

适用于：

- 需要 Wi-Fi、4G 或 5G 网络覆盖的测试；
- 已经使用支持模块或脚本的代理客户端；
- 希望由第三方客户端继续保持代理配置的场景。

当前客户端状态：

| 客户端 | 状态 | 社区配置 |
|---|---|---|
| Shadowrocket | 当前用于真机测试 | App 内置教程 |
| Surge | 已提供配置，尚未完整验证 | 待征集 |
| Quantumult X | 已提供配置，尚未完整验证 | 待征集 |
| Loon | 已提供配置，尚未完整验证 | 待征集 |
| Stash | 已提供配置，尚未完整验证 | 待征集 |
| Egern | 使用 Surge 模块，尚未完整验证 | 待征集 |

社区配置按客户端分区审核；采纳后会在上表链接教程和投稿者，投稿者也可以选择匿名收录。

相关模块快照和来源记录：

- [第三方模块说明](docs/THIRD_PARTY_MODULES.md)
- [Yu9191/wloc](https://github.com/Yu9191/wloc)

第三方客户端、证书、MITM 和代理开关由客户端自身负责。导入任何第三方模块前，请先审查其配置和脚本内容。

## 快速开始

### 1. 安装应用

你可以使用：

- 自己的 Apple Developer 签名环境；
- 适合个人测试的自签工具；
- 项目 Releases 中的未签名 IPA；
- 在 macOS 上按[构建说明](docs/BUILD.md)自行构建。

免费自签环境可能无法使用 Network Extension，因此 APP 模式采用设备内本地代理和 Wi-Fi 手动代理，不依赖
VPN 组件。内置 VPN 模式必须使用付费 Apple Developer 账号，并在签名时为扩展
（`PaopaoVPNExtension.appex`）注入 `Scripts/impactor-entitlements-extension.plist` 中的权限；缺少
`packet-tunnel-provider` 权限时，App 内启用隧道会超时并提示签名要求。

#### 自签安装说明

Release 附件是未签名 IPA，需要使用自签工具安装到 iPhone：

1. **开启自签支持**：iOS 16 及以上版本前往“设置 → 隐私与安全性 → 开发者模式”，开启后按系统提示重启并
   确认；iOS 15 没有此开关，可跳过本步。
2. **下载 IPA**：前往本项目的 [Releases](https://github.com/xweiba/location-spoofer/releases)，下载最新的
   `PaopaoLocationSpoofer-unsigned.ipa`。
3. **准备自签软件**：前往 [Impactor Releases](https://github.com/claration/Impactor/releases) 下载对应系统
   版本的 Impactor；也可以使用爱思助手等支持 IPA 自签安装的软件。
4. **连接并安装**：使用 USB 数据线连接 iPhone 与电脑，在手机上选择“信任此电脑”，然后在自签软件中选择
   刚下载的 IPA，根据软件提示完成签名与安装。使用内置 VPN 模式时，请为 App 与扩展分别应用
   `Scripts/impactor-entitlements-app.plist` 和 `Scripts/impactor-entitlements-extension.plist`。

Impactor 支持 Windows、macOS 和 Linux；Windows 若无法识别设备，请先安装 iTunes 提供的 Apple 设备驱动。
爱思助手属于第三方软件，请从其官方渠道获取，并自行评估账号、证书和隐私风险。

安装完成后，若 iOS 阻止打开 App，请前往“设置 → 通用 → VPN 与设备管理”信任对应的开发者 App。免费
Apple ID 自签通常只有 7 天有效期，到期后需要重新签名安装。

### 2. 首次启动

首次启动时：

1. 选择 APP 模式、内置 VPN 模式或第三方代理模式；
2. 按照 App 内引导完成对应配置；
3. 执行环境检测；
4. 在地图中搜索、点击或拖动选择测试位置；
5. 启用测试位置并在目标测试环境中验证结果。

### 3. 恢复真实位置

APP 模式：

1. 停止测试位置；
2. 关闭当前 Wi-Fi 的手动 HTTP 代理；
3. 按 App 内提示刷新定位环境。

内置 VPN 模式：

1. 停止测试位置；
2. 在 App 设置或系统设置中断开内置 VPN；
3. 按 App 内提示刷新定位环境。

第三方代理模式：

1. 使用 App 清除 WLOC 坐标；
2. 在第三方客户端中关闭对应模块或代理；
3. 按客户端要求恢复 HTTPS 解密和代理设置。

如果系统或目标应用仍显示旧位置，可能需要等待定位缓存刷新，必要时重启设备后再次验证。

## 坐标处理

项目内部保存两种坐标表示：

- WGS-84：国际标准，WLOC 写入使用此坐标；
- GCJ-02：国内地图标准，用于需要国内地图坐标的场景。

MapKit 不提供公开 API 直接返回当前是否使用 GCJ-02 或 WGS-84。项目通过固定锚点查询判断 MapKit 当前返回
标准，并在运行期间根据蓝点变化和用户操作进行受控刷新。

坐标写入边界会保存完整的 WGS-84 / GCJ-02 坐标对，使用时根据当前地图标准选择对应字段，避免重复转换造成
位置偏移。

## 项目结构

```text
App/           SwiftUI 界面、MapKit、定位和运行流程
Core/          Go 代理、证书服务和定位响应处理
Shared/        坐标、收藏、日志、配置和共享模型
VPNExtension/  内置 VPN 的 Network Extension（Packet Tunnel）
Resources/     Info.plist、Entitlements 和资源文件
Config/        构建配置
Scripts/       构建、打包和验证脚本
Tests/         XCTest 和 Shell contract tests
docs/          构建、模块和版本文档
```

## 构建项目

源码构建需要 macOS 环境：

- macOS；
- Xcode；
- Xcode Command Line Tools；
- XcodeGen；
- Go 1.23 或更高版本。

当前项目不支持在 Windows 上直接构建 iOS 应用。

```bash
git clone https://github.com/xweiba/location-spoofer.git
cd location-spoofer

./build.sh
```

运行构建并执行 Simulator 测试：

```bash
./build.sh --test
```

构建脚本会生成未签名 IPA：

```text
dist/PaopaoLocationSpoofer-unsigned.ipa
```

之后需要使用你自己的签名和安装流程部署到测试设备。

## 隐私与安全边界

- 项目不包含遥测或远程控制服务；
- 项目不会自动上传用户位置数据；
- 运行日志保存在设备 App Group 容器中，并自动保留近三天；
- 问题报告需要用户主动复制后提交到 GitHub；
- APP 模式会访问本机代理和环境验证地址；
- 第三方代理模式可能访问上游模块地址和 WLOC 配置接口；
- App 生成的 CA 私钥保存在设备 Keychain 中；
- 第三方客户端模块、MITM 和证书链路由用户选择的客户端负责。

请不要把真实位置、认证信息、证书私钥或完整敏感日志提交到公开 Issue。

## 限制

- iOS 系统版本变化可能影响定位服务行为；
- MapKit 的坐标返回标准可能随系统、地区和定位环境变化；
- 系统定位存在缓存，切换位置后不一定立即生效；
- 第三方代理客户端的兼容性和规则行为需要分别验证；
- 不保证所有应用都使用同一种定位 API；
- 不保证所有应用或服务都接受测试坐标；
- 不保证在所有网络环境、设备型号和 iOS 版本上表现一致。

## 贡献

欢迎提交：

- [Bug Report](https://github.com/xweiba/location-spoofer/issues/new?template=bug-report.yml)；
- [功能建议](https://github.com/xweiba/location-spoofer/discussions/categories/%E5%8A%9F%E8%83%BD%E5%BB%BA%E8%AE%AE)；
- [使用帮助与兼容性测试](https://github.com/xweiba/location-spoofer/discussions/categories/%E4%BD%BF%E7%94%A8%E5%B8%AE%E5%8A%A9)；
- [第三方客户端配置和脱敏原始截图](https://github.com/xweiba/location-spoofer/discussions/categories/%E7%AC%AC%E4%B8%89%E6%96%B9%E9%85%8D%E7%BD%AE%E5%88%86%E4%BA%AB)；
- 性能改进；
- 文档改进；
- 测试补充。

提交 Bug 时建议优先通过 App 的“设置 → 支持 → 报告 Bug”生成报告。报告包含：

- iOS 版本；
- App 版本；
- 使用的运行模式；
- 当前第三方客户端；
- 是否可以稳定复现；
- 问题描述；
- 脱敏后的运行日志；

GitHub Issue Form 中的“App 生成的诊断报告”字段与 App 复制内容一一对应。

## 文档

- [构建说明](docs/BUILD.md)
- [第三方模块说明](docs/THIRD_PARTY_MODULES.md)
- [社区客户端教程与截图提交](docs/COMMUNITY_TUTORIALS.md)
- [更新日志](docs/CHANGELOG.md)
- [英文文档](README.en.md)
- [GitHub Issues](https://github.com/xweiba/location-spoofer/issues)

## 功能预览

以下截图用于展示主界面和部分真机测试场景。实际结果会受到 iOS 版本、网络环境、系统缓存和目标应用定位策略
影响，不代表对所有应用或版本作出兼容性保证。

<table>
  <tr>
    <th>应用主界面</th>
    <th>Apple 地图测试</th>
    <th>高德地图测试</th>
  </tr>
  <tr>
    <td><img src="images/主界面.jpg" alt="Location Spoofer 地图选点主界面" width="220"></td>
    <td><img src="images/Apple%20Map.jpg" alt="Apple 地图定位测试场景" width="220"></td>
    <td><img src="images/高德地图.jpg" alt="高德地图定位测试场景" width="220"></td>
  </tr>
  <tr>
    <th>微信测试</th>
    <th>钉钉测试</th>
    <th>Apple Watch 场景测试</th>
  </tr>
  <tr>
    <td><img src="images/微信.jpg" alt="微信定位测试场景" width="220"></td>
    <td><img src="images/钉钉.jpg" alt="钉钉定位测试场景" width="220"></td>
    <td><img src="images/高血压.jpg" alt="Apple Watch 地区功能测试场景" width="220"></td>
  </tr>
</table>

## 致谢与友链

核心定位响应处理思路、Go 实现和第三方模块参考自：

- [Yu9191/wloc](https://github.com/Yu9191/wloc)
- [ios-location-spoofer](https://github.com/mekos2772/ios-location-spoofer)

感谢以下 LINUX DO 用户对项目的贡献：

- 功能修复：[陈泽](https://linux.do/u/lixiaobaivv)
- 思路及建议：[Alex](https://linux.do/u/_alex)、[ye4241](https://linux.do/u/ye4241)

友链：

- [LINUX DO](https://linux.do/)
- [iOS-Location-Spoofer-Web](https://github.com/akudamatata/iOS-Location-Spoofer-Web)

感谢开源社区中参与 iOS 定位服务研究、网络代理和移动端测试工具建设的贡献者。
