<div align="center">

# 📍 Location Spoofer

### iOS 虚拟定位 · 钉钉定位 · 微信定位 · Apple Watch 国区功能解锁 · Fake GPS

**无需越狱；通过 APP 模式的本机 Wi‑Fi HTTP 代理，或第三方代理模式（Wi‑Fi/4G/5G）改写 Apple 定位服务响应。**<br>
适用于钉钉、微信、Apple 地图等读取系统定位的 App。地图选点、收藏、模式配置、环境检测和问题诊断集中在一个 App 中。

[![iOS 15+](https://img.shields.io/badge/iOS-15%2B-111111?logo=apple)](project.yml)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](project.yml)
[![Go 1.23+](https://img.shields.io/badge/Go-1.23%2B-00ADD8?logo=go&logoColor=white)](Core/go.mod)
[![Version](https://img.shields.io/badge/version-v1.0.1-2563EB)](docs/CHANGELOG.md)
[![App Mode](https://img.shields.io/badge/APP模式-无需VPN-16A34A)](#工作原理)

[功能介绍](#核心功能) · [快速开始](#快速开始) · [工作原理](#工作原理) · [English](README.en.md) · [更新日志](docs/CHANGELOG.md)

<img src="images/主界面.jpg" alt="Location Spoofer iOS 虚拟定位 Fake GPS 主界面" width="380">

</div>

> [!IMPORTANT]
> 本项目仅用于学习、安全研究和自有设备测试。APP 模式需要安装本机生成的 CA，并为当前 Wi‑Fi 配置 HTTP 代理；第三方代理模式的证书、MITM 及代理/VPN 连接由所选客户端负责。实际效果受 iOS、网络、定位缓存和目标 App 策略影响，请遵守当地法律、网络管理规则及相关服务条款。

## 致谢

核心定位响应改写思路与 Go 实现来源于 [Yu9191/wloc](https://github.com/Yu9191/wloc)。本项目在此基础上增加 SwiftUI 界面、MapKit 选点、证书与代理引导、环境验证、收藏和诊断能力。

## 为什么选择 Location Spoofer？

很多 iOS 虚拟定位工具依赖电脑常驻、开发者调试或越狱。本项目把选点和控制流程放在 iPhone 上，并提供两条互斥的运行路径：由 App 在本机启动 Go 代理，或把坐标同步给已有的第三方代理客户端。

| 特性 | 说明 |
|---|---|
| 🔀 **双运行模式** | APP 模式无需第三方客户端、适用于 Wi‑Fi；第三方代理模式可随客户端覆盖 Wi‑Fi、4G 和 5G |
| 📱 **无需越狱** | 支持自行签名安装，最低部署目标为 iOS 15 |
| 🗺️ **原生地图体验** | 使用 Apple 地图同款蓝点，搜索、点击、拖动选点体验与 Apple 地图一致 |
| 📍 **系统定位响应改写** | 可影响钉钉、微信、Apple 地图、高德等读取系统定位的 App，兼容性以真机结果为准 |
| 🔍 **可见缩放范围** | 左侧缩放控件显示当前可视范围，地点名称随级别自动适配 |
| 🧭 **坐标一致性** | 自动处理 MapKit 地图坐标与 WGS-84，收藏、恢复和第三方同步使用明确的坐标来源 |
| 🧪 **按模式检测** | APP 模式检查本地代理、CA 信任和 Wi‑Fi 链路；第三方模式验证模块是否真正拦截请求 |
| 🧾 **问题诊断** | 日志可搜索、逐条或整体复制，并可生成已脱敏的 GitHub Issue 报告 |

## 效果预览

<table>
  <tr>
    <th>应用主界面</th>
    <th>钉钉</th>
    <th>微信</th>
  </tr>
  <tr>
    <td><img src="images/主界面.jpg" alt="iOS 虚拟定位应用主界面" width="180"></td>
    <td><img src="images/钉钉.jpg" alt="钉钉虚拟定位打卡" width="180"></td>
    <td><img src="images/微信.jpg" alt="微信虚拟定位" width="180"></td>
  </tr>
  <tr>
    <th>Apple 地图</th>
    <th>高德地图</th>
    <th>Apple Watch</th>
  </tr>
  <tr>
    <td><img src="images/Apple%20Map.jpg" alt="Apple Maps 定位效果" width="180"></td>
    <td><img src="images/高德地图.jpg" alt="高德地图定位效果" width="180"></td>
    <td><img src="images/高血压.jpg" alt="Apple Watch 地区功能验证" width="180"></td>
  </tr>
</table>

## 核心功能

- **iOS 虚拟定位 / Fake GPS**：将当前选点写入 APP 模式代理，或同步给第三方 WLOC 模块。
- **原生地图与实时位置**：使用 MapKit 蓝点，支持搜索、点击、拖动地图中心、缩放以及快速打开 Apple 地图。
- **并发安全选点**：拖动、点击、搜索、收藏和异步定位按用户最新意图处理，旧结果不会覆盖新选点。
- **地点名称分级**：近距离显示 POI、门牌或道路；拉远后显示社区、区县、城市或省份。
- **地图范围显示**：缩放控件中显示 `180 m`、`2.5 km`、`126 km` 等当前可视范围。
- **收藏与状态恢复**：保存、重命名和切换常用位置，记住最后图钉与地图范围。
- **坐标系自动处理**：启动时确认地图坐标标准，内部保留 WGS-84 与地图坐标配对，减少中国大陆地图偏移。
- **分模式首次引导**：APP 模式配置本机代理和 CA；第三方模式选择客户端、复制订阅地址并检测连接。
- **本机代理保活**：APP 模式启动虚拟定位后使用静音音频维持后台运行，并响应网络切换重新检测环境。
- **结构化诊断**：运行日志自动轮转，仅保留近 3 天；支持过滤、复制、清空和生成 Issue 报告。
- **第三方代理模式（测试）**：向模块查询、保存或清除 WGS-84 坐标；坐标由代理客户端持久化，关闭本 App 后仍可能继续生效。

## 快速开始

### 1. 安装 App

- 从 [Releases](https://github.com/xweiba/location-spoofer/releases) 获取构建产物并自行签名；或
- 在 macOS + Xcode 环境按[构建说明](docs/BUILD.md)编译。

#### 自签安装

免费 Apple ID 可用于侧载，无需付费开发者账号。本项目自身不包含 VPN、Network Extension 或 Packet Tunnel Provider，但签名工具仍需保留 App 的标识和声明能力。

需要自行构建时执行：

```bash
./build.sh
```

输出文件为 `dist/PaopaoLocationSpoofer-unsigned.ipa`。也可以直接下载 Release 附带的未签名 IPA，然后使用 [Impact](https://github.com/claration/Impactor) 签名并安装到设备。

签名时不要修改以下标识，也不要移除 App Group 和 Wi-Fi 信息能力：

| 组件 | 标识 |
|---|---|
| 主 App Bundle ID | `com.paopaolabs.location-spoofer` |

免费 Apple ID 签名通常只有 7 天有效期，到期后需要重新签名安装；这是 Apple 的侧载限制，不是 WLOC CA 失效。CA 私钥保存在 iOS 钥匙串中：相同 Bundle ID 和钥匙串访问范围下重装通常可以复用，但卸载、系统清理或签名能力变化后不保证保留。

### 2. 选择运行模式

#### APP 模式（本机 Wi‑Fi）

首次打开后选择 APP 模式，再按 App 内引导配置代理和 CA。此模式会在设备内启动 `wloccore`，不依赖第三方代理客户端，但流量入口只覆盖当前 Wi‑Fi。

##### 配置当前 Wi‑Fi 代理

首次打开后，先在当前 Wi‑Fi 的“配置代理”中选择“手动”：

```text
服务器：127.0.0.1
端口：8888
鉴定：关闭
```

返回 App 后运行环境检测；若设备尚未信任 CA，App 会进入完整的证书初始化流程。

##### 安装并信任 CA

按首次引导下载描述文件，然后依次完成：

```text
设置 → 通用 → VPN 与设备管理 → 安装 WLOC CA
设置 → 通用 → 关于本机 → 证书信任设置 → 完全信任
```

#### 第三方代理模式（测试）

此模式由 App 负责地图选点、收藏以及查询、同步和清除 WGS-84 坐标；WLOC 拦截、MITM 与坐标持久化由第三方代理客户端负责。它不会启动本机 Go 代理，不使用 App 生成的 CA，也不要求配置 `127.0.0.1:8888`。网络覆盖范围取决于代理客户端，可包括 Wi‑Fi、4G 和 5G。

首次引导或“设置 → 运行模式”切换后，选择客户端。App 提供官方订阅地址复制和客户端跳转按钮；在对应客户端的模块、重写或覆写订阅入口粘贴地址并导入。仓库和 App 包内仍保留以下模块配置快照，用于版本归档和离线核对：

| 客户端 | 状态 | 模块 |
|---|---|---|
| Shadowrocket（小火箭） | **当前可测试** | [wloc.module](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.module) |
| Surge | 配置已提供，尚未验证 | [wloc.sgmodule](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.sgmodule) |
| Quantumult X | 配置已提供，尚未验证 | [wloc.conf](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.conf) |
| Loon | 配置已提供，尚未验证 | [wloc.lpx](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.lpx) |
| Stash | 配置已提供，尚未验证 | [wloc.stoverride](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.stoverride) |
| Egern | 配置已提供，尚未验证 | 直接使用 Surge 模块 |

Shadowrocket 还需为 `gs-loc.apple.com` 开启 HTTPS 解密。Stash 应直接订阅 `.stoverride`，无需通过 Script Hub 转换；Egern 复用 Surge 配置。导入后仍需按客户端自己的流程启用模块、MITM、证书和代理/VPN 连接，这些状态不由本 App 管理。“检测连接”只有在接口返回有效模块 JSON 时才会通过，普通 HTTP 200 不会被误判为成功。

> 第三方代理模式目前是测试模式。内置模块快照来源及版本记录见 [第三方模块说明](docs/THIRD_PARTY_MODULES.md)；模块引用的运行脚本仍由第三方客户端按配置访问。上游更新可能改变行为；当前仅计划使用 Shadowrocket 做真机验证。

### 3. 选点并启用

1. 搜索、点击或拖动地图选择位置；点击定位按钮可回到当前 MapKit 蓝点，也可以保存为收藏。
2. APP 模式点击“开始虚拟定位”并等待环境检测；第三方代理模式点击“同步到第三方代理”。
3. 按 App 内“生效说明”刷新飞行模式、Wi‑Fi 和定位服务状态。
4. 打开 Apple 地图或目标 App 验证结果。

### 4. 恢复真实位置

APP 模式下先停止虚拟定位，再关闭当前 Wi‑Fi 的手动代理；第三方代理模式下使用“清除第三方代理坐标”，必要时再停用对应模块或代理连接。随后按 App 内“失效说明”刷新系统定位缓存；若仍保留旧位置，请重启设备后再检查。

## 工作原理

### APP 模式为什么不需要 VPN？

```text
iPhone 定位请求
      │ 当前 Wi‑Fi HTTP 代理：127.0.0.1:8888
      ▼
本机 wloccore（Go）
      │ 仅处理目标 Apple 定位服务请求
      ├──────────────► Apple 定位服务
      ◄──────────────┘
      │ 改写目标响应中的坐标
      ▼
系统与应用读取定位结果
```

APP 模式不使用 Network Extension 创建 VPN 隧道，因此不会显示 VPN 连接，也不会占用系统 VPN。**它仍然需要当前 Wi‑Fi 的手动 HTTP 代理以及已完全信任的本机 CA。**

### 第三方代理模式

```text
地图选点（WGS-84） → WLOC 配置接口 → 第三方代理模块保存坐标
                                      │
系统定位请求 → 第三方客户端代理/VPN + MITM ─┘→ 改写定位响应
```

第三方模式由所选客户端管理代理/VPN、证书和 MITM，可覆盖蜂窝网络。两种模式不要同时拦截 WLOC 请求。

## 数据与安全说明

- APP 模式的 CA 和私钥在设备本地生成，私钥存入 iOS 钥匙串；安装到系统的是 CA 描述文件。
- 第三方代理模块及运行脚本来自上游项目，导入前请自行检查；仓库内快照用于版本留档，不代表已验证所有客户端。
- 运行日志位于 App Group 容器，自动轮转并仅保留近 3 天；可在 App 内复制或清空。可导出的实时定位诊断默认不记录精确坐标。
- 使用自签 CA 或第三方 MITM 都会改变设备的 HTTPS 信任/代理链路；不用时应关闭代理或模块，并按需移除证书。

## 兼容性

| 项目 | 要求 |
|---|---|
| iOS | 15.0+ |
| 构建 | macOS、Xcode、XcodeGen |
| Swift | 5.9 |
| Go | 1.23+ |
| 网络 | APP 模式：可手动配置 HTTP 代理的 Wi‑Fi；第三方代理模式（测试）：取决于客户端，可覆盖 Wi‑Fi/4G/5G |
| 安装 | 自行签名或使用 Releases 构建产物 |

效果会受到 iOS 版本、网络、系统定位缓存和目标 App 自身策略影响，不承诺兼容所有系统或第三方 App。

## 构建与项目结构

构建要求为 macOS、Xcode Command Line Tools、Go 1.23+ 和 XcodeGen。执行：

```bash
./build.sh          # 构建未签名 IPA
./build.sh --test   # 构建后额外运行 iOS Simulator 单元测试
```

构建产物默认位于：

```text
dist/PaopaoLocationSpoofer-unsigned.ipa
```

```text
App/        SwiftUI、MapKit、定位和配置流程
Core/       Go 本机代理与定位响应改写
Shared/     收藏、设置、日志和共享模型
Resources/  Info.plist、Entitlements 与图标
Config/     构建配置
Scripts/    构建、签名和检查脚本
Tests/      XCTest 与 Bash 契约测试
docs/       构建、第三方模块和版本发布文档
```

## 文档与反馈

- [构建说明](docs/BUILD.md)
- [第三方模块说明](docs/THIRD_PARTY_MODULES.md)
- [更新日志](docs/CHANGELOG.md)
- [English README](README.en.md)
- [GitHub Issues](https://github.com/xweiba/location-spoofer/issues)

反馈问题时，请附上复现步骤、iOS 版本、设备型号及已脱敏的运行日志。

## 友链

**LinuxDo** — [https://linux.do](https://linux.do/)
