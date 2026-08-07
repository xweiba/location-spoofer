<div align="center">

# 📍 Location Spoofer

### iOS Location Spoofer · DingTalk · WeChat · Apple Watch Region Unlock · Fake GPS

**No jailbreak — rewrite Apple location-service responses through App Mode's on-device Wi-Fi HTTP proxy or Third-party Proxy Mode (Wi-Fi/4G/5G).**<br>
Designed for DingTalk, WeChat, Apple Maps, and other apps that read system location. Map selection, favorites, mode setup, environment checks, and diagnostics live in one app.

[![iOS 15+](https://img.shields.io/badge/iOS-15%2B-111111?logo=apple)](project.yml)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](project.yml)
[![Go 1.23+](https://img.shields.io/badge/Go-1.23%2B-00ADD8?logo=go&logoColor=white)](Core/go.mod)
[![Version](https://img.shields.io/badge/version-v1.0.1-2563EB)](docs/CHANGELOG.md)
[![App Mode](https://img.shields.io/badge/App%20Mode-No%20VPN-16A34A)](#how-it-works)

[Features](#key-features) · [Quick Start](#quick-start) · [How It Works](#how-it-works) · [中文](README.md) · [Changelog](docs/CHANGELOG.md)

<img src="images/主界面.jpg" alt="Location Spoofer iOS Fake GPS main interface" width="380">

</div>

> [!IMPORTANT]
> This project is only for education, security research, and testing on devices you own. App Mode requires a locally generated CA and a manual HTTP proxy on the current Wi-Fi network. In Third-party Proxy Mode, the selected client owns certificate, MITM, and proxy/VPN setup. Results vary by iOS version, network, location cache, and target-app behavior. Follow applicable laws, network policies, and service terms.

## Credits

The core location-response rewriting approach and Go implementation are based on [Yu9191/wloc](https://github.com/Yu9191/wloc). This project adds a SwiftUI interface, MapKit selection, certificate and proxy guidance, environment verification, favorites, and diagnostics.

## Why Location Spoofer?

Unlike tools that require a computer to stay connected, developer debugging, or a jailbroken device, Location Spoofer keeps selection and control on the iPhone. It provides two mutually exclusive paths: run the Go proxy inside the app, or synchronize coordinates to an existing third-party proxy client.

| Feature | Description |
|---|---|
| 🔀 **Two runtime modes** | App Mode needs no third-party client and works over Wi-Fi; Third-party Proxy Mode can follow its client across Wi-Fi, 4G, and 5G. |
| 📱 **No jailbreak** | Can be installed through self-signing; minimum deployment target is iOS 15. |
| 🗺️ **Native Maps experience** | The same blue dot and selection gestures as Apple Maps — search, tap, and drag. |
| 📍 **Location-response rewriting** | Can affect DingTalk, WeChat, Apple Maps, Amap, and other apps that read system location; verify compatibility on-device. |
| 🔍 **Visible map scale** | Left-side controls show the current visible range; place name adapts to zoom level. |
| 🧭 **Coordinate consistency** | Reconciles MapKit map coordinates with WGS-84 for favorites, restoration, and third-party sync. |
| 🧪 **Mode-aware checks** | App Mode checks the local proxy, CA trust, and Wi-Fi path; Third-party Mode verifies real module interception. |
| 🧾 **Diagnostics** | Search and copy logs, or generate a sanitized GitHub Issue report from inside the app. |

## Screenshots

| Main Interface | Apple Maps | Amap | Apple Watch |
|---|---|---|---|
| ![Location Spoofer main interface](images/主界面.jpg) | ![Apple Maps result](images/Apple%20Map.jpg) | ![Amap result](images/高德地图.jpg) | ![Apple Watch region feature](images/高血压.jpg) |

## Key Features

- **iOS Location Spoofer / Fake GPS**: Apply the selected pin to App Mode's proxy or synchronize it to a third-party WLOC module.
- **Native map and real-time location**: Uses MapKit's blue dot with search, tap, map-center drag, zoom controls, and a shortcut to Apple Maps.
- **Concurrency-safe selection**: Pan, tap, search, favorites, and async location respect the user's latest intent; stale results won't overwrite newer selections.
- **Hierarchical place names**: POI, street, or road at close zoom; neighborhood, district, city, or province at wider zoom.
- **Map scale display**: Zoom controls show the current visible range.
- **Favorites and state restoration**: Save, rename, and switch frequent locations while remembering the last pin and map range.
- **Automatic coordinate handling**: Resolves the map's coordinate convention at startup and keeps paired WGS-84/map coordinates to reduce mainland-China map offsets.
- **Mode-specific onboarding**: App Mode guides local proxy and CA setup; Third-party Mode guides client selection, subscription import, and connection testing.
- **Local-proxy keep-alive**: App Mode uses silent audio while spoofing to remain active in the background and rechecks the environment after Wi-Fi changes.
- **Structured diagnostics**: Logs rotate automatically, retain only three days, and can be filtered, copied, cleared, or attached to an Issue report.
- **Third-party Proxy Mode (testing)**: Query, save, or clear WGS-84 coordinates through a WLOC module. The proxy client persists state, so spoofing may continue after this app closes.

## Quick Start

### 1. Install the App

- Download a build from [Releases](https://github.com/xweiba/location-spoofer/releases) and self-sign; or
- Build from source on macOS with Xcode — see the [build guide](docs/BUILD.md).

The release asset is an unsigned IPA. Sign it with [Impact](https://github.com/claration/Impactor) before installation. Keep the app Bundle ID `com.paopaolabs.location-spoofer`, the App Group `group.com.paopaolabs.location-spoofer`, and the declared entitlements unchanged. A free Apple ID signature normally expires after seven days and must then be renewed; this is separate from the WLOC CA certificate.

### 2. Choose a Runtime Mode

#### App Mode (On-device Wi-Fi)

Choose App Mode during first launch, then follow the in-app guide to configure the proxy and CA. This mode starts `wloccore` on the device and has no third-party client dependency, but its traffic entry point covers only the current Wi-Fi.

On the current Wi-Fi network, set Configure Proxy to Manual:

```text
Server: 127.0.0.1
Port: 8888
Authentication: off
```

Return to the app and run the environment check. If the CA is not trusted, the app opens the complete certificate setup flow. Download the profile, then:

```text
Settings → General → VPN & Device Management → install WLOC CA
Settings → General → About → Certificate Trust Settings → enable full trust
```

#### Third-party Proxy Mode (Testing)

The app handles map selection, favorites, and querying, saving, or clearing WGS-84 coordinates. A third-party proxy client handles WLOC interception, MITM, and persistence. This mode does not start the local Go proxy, use the app-generated CA, or require `127.0.0.1:8888`. Network coverage depends on the selected client and may include Wi-Fi, 4G, and 5G.

Select a client during onboarding or from Settings → Runtime Mode. The app can copy the official subscription URL and open the selected client; paste that URL into its module, rewrite, or override subscription UI.

| Client | Verification status | Configuration |
|---|---|---|
| Shadowrocket | **Currently available for testing** | [wloc.module](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.module) |
| Surge | Provided, not verified | [wloc.sgmodule](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.sgmodule) |
| Quantumult X | Provided, not verified | [wloc.conf](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.conf) |
| Loon | Provided, not verified | [wloc.lpx](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.lpx) |
| Stash | Provided, not verified | [wloc.stoverride](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.stoverride) |
| Egern | Provided, not verified | Uses the Surge module |

For Shadowrocket, also enable HTTPS decryption for `gs-loc.apple.com`. Import `.stoverride` directly into Stash without Script Hub conversion; Egern reuses the Surge module. The client—not this app—owns module enablement, MITM, certificates, and proxy/VPN state. A connection test passes only when the endpoint returns valid module JSON, not merely HTTP 200. Bundled snapshots and provenance are documented in [Third-party Module Snapshots](docs/THIRD_PARTY_MODULES.md).

### 3. Select a Location & Enable

1. Search, tap, or drag the map to pick a location; use the location button to return to the MapKit blue dot, or save the pin as a favorite.
2. In App Mode, tap “Start Spoofing” and wait for verification. In Third-party Proxy Mode, tap “Sync to Third-party Proxy.”
3. Follow the in‑app activation instructions to refresh airplane mode, Wi‑Fi, and location services.
4. Open Apple Maps or your target app to verify.

### 4. Restore Your Real Location

In App Mode, stop spoofing and disable the current Wi-Fi's manual proxy. In Third-party Mode, use “Clear Third-party Proxy Coordinates,” then disable the module or proxy connection if needed. Follow the in-app deactivation instructions to refresh the system location cache; restart the device if the old location remains.

## How It Works

### Why App Mode Needs No VPN

```text
iPhone location request
        │ Wi‑Fi HTTP proxy: 127.0.0.1:8888
        ▼
Local wloccore Go proxy
        │ Handles only the targeted Apple location-service traffic
        ▼
Apple location service response
        │ The selected coordinate is written into the response
        ▼
The system and applications receive the modified result
```

App Mode does not create a Network Extension tunnel, so it does not display or occupy a VPN connection. **It still requires the current Wi-Fi's manual HTTP proxy and a fully trusted local CA.**

### Third-party Proxy Mode

```text
Map pin (WGS-84) → WLOC settings endpoint → proxy module stores coordinate
                                             │
Location request → third-party proxy/VPN + MITM ┘→ rewritten response
```

The selected client owns proxy/VPN, certificates, and MITM and may cover cellular networks. Do not enable both interception paths at once.

## Data & Security Notes

- App Mode generates its CA and private key on-device. The private key is stored in the iOS Keychain; only the CA profile is installed into the system trust store.
- Third-party modules and runtime scripts come from the upstream project. Review them before importing. Bundled snapshots provide release provenance and do not imply that every client has been verified.
- Runtime logs live in the App Group container, rotate automatically, and retain only three days. They can be copied or cleared in-app. Exportable real-time-location diagnostics omit exact coordinates by default.
- A self-signed CA or third-party MITM changes the device's HTTPS trust/proxy path. Disable the proxy or module when unused and remove certificates if appropriate.

## Compatibility

| Item | Requirement |
|---|---|
| iOS | 15.0+ |
| Build | macOS, Xcode, XcodeGen |
| Swift | 5.9 |
| Go | 1.23+ |
| Network | App Mode: Wi-Fi with manual HTTP proxy support; Third-party Mode (testing): client-dependent Wi-Fi/4G/5G |
| Installation | Self-sign or use release builds |

Actual behavior may vary with iOS version, network conditions, system location cache, device model, and the target app's own location strategy. Compatibility with every iOS version or third-party app is not guaranteed.

## Build & Project Structure

Building requires macOS, Xcode Command Line Tools, Go 1.23+, and XcodeGen:

```bash
./build.sh          # build the unsigned IPA
./build.sh --test   # also run iOS Simulator unit tests
```

The unsigned IPA is at:

```text
dist/PaopaoLocationSpoofer-unsigned.ipa
```

```text
App/        SwiftUI, MapKit, location and setup flow
Core/       Go local proxy and location response rewriting
Shared/     Favorites, settings, logs, and shared models
Resources/  Info.plist, Entitlements, and icons
Config/     Build configuration
Scripts/    Build, signing, and verification scripts
Tests/      XCTest and Bash contract tests
docs/       Build, third-party module, and release documentation
```

## Documentation & Feedback

- [Build guide](docs/BUILD.md)
- [Third-party module snapshots](docs/THIRD_PARTY_MODULES.md)
- [Changelog](docs/CHANGELOG.md)
- [中文文档](README.md)
- [GitHub Issues](https://github.com/xweiba/location-spoofer/issues)

When reporting issues, please include reproduction steps, iOS version, device model, and sanitized runtime logs.

## Links

**LinuxDo** — [https://linux.do](https://linux.do/)
