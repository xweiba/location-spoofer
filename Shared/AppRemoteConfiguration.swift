import Foundation

struct AppUpdatePrompt: Identifiable, Equatable {
    enum Requirement: String {
        case recommended
        case required
    }

    let currentVersion: String
    let latestVersion: String
    let minimumSupportedVersion: String
    let requirement: Requirement
    let releaseNotes: String?

    var id: String {
        "\(requirement.rawValue)-\(latestVersion)-\(minimumSupportedVersion)"
    }
}

struct AppRemoteConfiguration: Decodable, Equatable {
    let latestVersion: String
    let minimumSupportedVersion: String
    let communityPromptClients: [String]

    static let fallback = AppRemoteConfiguration(
        latestVersion: "1.0.8",
        minimumSupportedVersion: "1.0.0",
        communityPromptClients: [
            ThirdPartyProxyClient.surge.rawValue,
            ThirdPartyProxyClient.quantumultX.rawValue,
            ThirdPartyProxyClient.loon.rawValue,
            ThirdPartyProxyClient.stash.rawValue,
            ThirdPartyProxyClient.egern.rawValue
        ]
    )

    init(
        latestVersion: String,
        minimumSupportedVersion: String,
        communityPromptClients: [String]
    ) {
        self.latestVersion = latestVersion
        self.minimumSupportedVersion = minimumSupportedVersion
        self.communityPromptClients = communityPromptClients
    }

    static func decode(_ data: Data) throws -> AppRemoteConfiguration {
        let configuration = try JSONDecoder().decode(AppRemoteConfiguration.self, from: data)
        guard let latest = NumericVersion(configuration.latestVersion),
              let minimum = NumericVersion(configuration.minimumSupportedVersion),
              minimum <= latest else {
            throw AppRemoteConfigurationError.invalidVersion
        }
        guard configuration.communityPromptClients.allSatisfy({
            ThirdPartyProxyClient(rawValue: $0) != nil
        }) else {
            throw AppRemoteConfigurationError.invalidClient
        }
        return configuration
    }

    func updatePrompt(currentVersion: String, releaseNotes: String? = nil) -> AppUpdatePrompt? {
        guard let current = NumericVersion(currentVersion),
              let latest = NumericVersion(latestVersion),
              let minimum = NumericVersion(minimumSupportedVersion) else {
            return nil
        }
        if current < minimum {
            return AppUpdatePrompt(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                minimumSupportedVersion: minimumSupportedVersion,
                requirement: .required,
                releaseNotes: releaseNotes
            )
        }
        if current < latest {
            return AppUpdatePrompt(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                minimumSupportedVersion: minimumSupportedVersion,
                requirement: .recommended,
                releaseNotes: releaseNotes
            )
        }
        return nil
    }

    func requestsCommunityPrompt(for client: ThirdPartyProxyClient) -> Bool {
        client != .shadowrocket && communityPromptClients.contains(client.rawValue)
    }
}

@MainActor
final class AppRemoteConfigurationStore: ObservableObject {
    static let shared = AppRemoteConfigurationStore()

    @Published private(set) var configuration = AppRemoteConfiguration.fallback

    func apply(_ configuration: AppRemoteConfiguration) {
        self.configuration = configuration
    }

    func requestsCommunityPrompt(for client: ThirdPartyProxyClient) -> Bool {
        configuration.requestsCommunityPrompt(for: client)
    }
}

enum AppRemoteConfigurationService {
    static let configurationURLs = [
        URL(
            string: "https://gh-proxy.org/https://raw.githubusercontent.com/xweiba/location-spoofer/main/version.txt"
        )!,
        URL(
            string: "https://raw.githubusercontent.com/xweiba/location-spoofer/main/version.txt"
        )!
    ]
    static let releasesURL = URL(
        string: "https://github.com/xweiba/location-spoofer/releases/latest"
    )!

    static func fetch() async -> AppRemoteConfiguration? {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        for url in configurationURLs {
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.5

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }
                let configuration = try AppRemoteConfiguration.decode(data)
                RuntimeLogger.info("APP", "Update", "远程版本配置加载成功", details: [
                    "来源": url.host ?? "未知",
                    "最新版本": configuration.latestVersion,
                    "最低版本": configuration.minimumSupportedVersion,
                    "社区征集客户端数": String(configuration.communityPromptClients.count)
                ])
                return configuration
            } catch {
                RuntimeLogger.info("APP", "Update", "版本配置源不可用，尝试下一地址", details: [
                    "来源": url.host ?? "未知",
                    "错误": error.localizedDescription
                ])
            }
        }

        RuntimeLogger.warning("APP", "Update", "版本配置加载失败，继续使用内置配置")
        return nil
    }

    static func fetchReleaseNotes(version: String) async -> String? {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        for url in releaseNotesURLs(version: version) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.5

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let markdown = String(data: data, encoding: .utf8),
                      let summary = releaseNotesSummary(markdown) else {
                    continue
                }
                return summary
            } catch {
                RuntimeLogger.info("APP", "Update", "版本说明源不可用，尝试下一地址", details: [
                    "来源": url.host ?? "未知",
                    "版本": version,
                    "错误": error.localizedDescription
                ])
            }
        }

        RuntimeLogger.info("APP", "Update", "版本说明加载失败，将使用最新 Release 页面", details: [
            "版本": version
        ])
        return nil
    }

    static func releaseNotesURLs(version: String) -> [URL] {
        let path = "https://raw.githubusercontent.com/xweiba/location-spoofer/main/docs/releases/v\(version).md"
        return [
            URL(string: "https://gh-proxy.org/\(path)")!,
            URL(string: path)!
        ]
    }

    private static func makeSession() -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 1.5
        sessionConfiguration.timeoutIntervalForResource = 2
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.waitsForConnectivity = false
        return URLSession(configuration: sessionConfiguration)
    }

    private static func releaseNotesSummary(_ markdown: String) -> String? {
        var items: [String] = []
        var inMainUpdates = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "## 主要更新" {
                inMainUpdates = true
                continue
            }
            if inMainUpdates, line.hasPrefix("## ") {
                break
            }
            guard inMainUpdates, line.hasPrefix("- ") else { continue }
            items.append("• " + line.dropFirst(2))
        }
        guard !items.isEmpty else { return nil }
        return items.joined(separator: "\n")
    }
}

private enum AppRemoteConfigurationError: Error {
    case invalidVersion
    case invalidClient
}

private struct NumericVersion: Comparable {
    let components: [Int]

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in parts {
            guard !part.isEmpty, let number = Int(part), number >= 0 else { return nil }
            parsed.append(number)
        }
        components = parsed
    }

    static func < (lhs: NumericVersion, rhs: NumericVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
