import XCTest
@testable import PaopaoLocationSpoofer

final class AppRemoteConfigurationTests: XCTestCase {
    func testDecodesReadableJSONAndClientPromptSwitches() throws {
        let data = """
        {
          "latestVersion": "1.2.0",
          "minimumSupportedVersion": "1.1.0",
          "communityPromptClients": ["surge", "loon"]
        }
        """.data(using: .utf8)!

        let configuration = try AppRemoteConfiguration.decode(data)

        XCTAssertEqual(configuration.latestVersion, "1.2.0")
        XCTAssertTrue(configuration.requestsCommunityPrompt(for: .surge))
        XCTAssertTrue(configuration.requestsCommunityPrompt(for: .loon))
        XCTAssertFalse(configuration.requestsCommunityPrompt(for: .stash))
        XCTAssertFalse(configuration.requestsCommunityPrompt(for: .shadowrocket))
    }

    func testVersionPolicyDistinguishesRequiredRecommendedAndCurrent() throws {
        let configuration = AppRemoteConfiguration(
            latestVersion: "1.2.0",
            minimumSupportedVersion: "1.1.0",
            communityPromptClients: []
        )

        XCTAssertEqual(
            configuration.updatePrompt(currentVersion: "1.0.9")?.requirement,
            .required
        )
        XCTAssertEqual(
            configuration.updatePrompt(currentVersion: "1.1.0")?.requirement,
            .recommended
        )
        XCTAssertNil(configuration.updatePrompt(currentVersion: "1.2.0"))
        XCTAssertNil(configuration.updatePrompt(currentVersion: "1.2.0.0"))
    }

    func testRejectsInvalidVersionsAndUnknownClients() {
        let invalidVersion = """
        {
          "latestVersion": "1.0.0",
          "minimumSupportedVersion": "2.0.0",
          "communityPromptClients": []
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try AppRemoteConfiguration.decode(invalidVersion))

        let invalidClient = """
        {
          "latestVersion": "2.0.0",
          "minimumSupportedVersion": "1.0.0",
          "communityPromptClients": ["unknown"]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try AppRemoteConfiguration.decode(invalidClient))
    }

    func testFallbackMatchesCurrentProjectPolicy() {
        let configuration = AppRemoteConfiguration.fallback

        XCTAssertEqual(configuration.latestVersion, "1.0.8")
        XCTAssertEqual(configuration.minimumSupportedVersion, "1.0.0")
        XCTAssertFalse(configuration.requestsCommunityPrompt(for: .shadowrocket))
        for client in ThirdPartyProxyClient.allCases where client != .shadowrocket {
            XCTAssertTrue(configuration.requestsCommunityPrompt(for: client))
        }
    }

    func testUpdateResourcesPreferDomesticMirrorAndRetainOfficialFallback() {
        XCTAssertEqual(AppRemoteConfigurationService.configurationURLs.first?.host, "gh-proxy.org")
        XCTAssertEqual(
            AppRemoteConfigurationService.configurationURLs.last?.host,
            "raw.githubusercontent.com"
        )

        let releaseNotesURLs = AppRemoteConfigurationService.releaseNotesURLs(version: "1.0.8", language: "en")
        XCTAssertEqual(releaseNotesURLs.first?.host, "gh-proxy.org")
        XCTAssertEqual(releaseNotesURLs.last?.host, "raw.githubusercontent.com")
        XCTAssertTrue(releaseNotesURLs.last?.path.hasSuffix("/docs/releases/v1.0.8.en.md") == true)
        XCTAssertTrue(AppRemoteConfigurationService.releaseNotesURLs(
            version: "1.0.8", language: "zh-Hans"
        ).last?.path.hasSuffix("/docs/releases/v1.0.8.md") == true)
        XCTAssertTrue(AppRemoteConfigurationService.releaseNotesURLs(
            version: "1.0.8", language: "zh-Hant"
        ).last?.path.hasSuffix("/docs/releases/v1.0.8.zh-Hant.md") == true)
        XCTAssertTrue(AppRemoteConfigurationService.releaseNotesURLs(
            version: "1.0.8", language: "it"
        ).last?.path.hasSuffix("/docs/releases/v1.0.8.en.md") == true)
    }

    func testReleaseNotesSummaryUsesTheSelectedLanguageHeading() {
        let english = "# v1.0.8\n\n## Highlights\n\n- English update\n\n## Installation"
        let chinese = "# v1.0.8\n\n## 主要更新\n\n- 中文更新\n\n## 安装"
        XCTAssertEqual(AppRemoteConfigurationService.releaseNotesSummary(english, language: "en"), "• English update")
        XCTAssertEqual(AppRemoteConfigurationService.releaseNotesSummary(chinese, language: "zh-Hans"), "• 中文更新")
        XCTAssertEqual(AppRemoteConfigurationService.releaseNotesSummary(chinese, language: "zh-Hant"), "• 中文更新")
        XCTAssertNil(AppRemoteConfigurationService.releaseNotesSummary(chinese, language: "en"))
        XCTAssertEqual(AppRemoteConfigurationService.releaseNotesSummary(english, language: "it"), "• English update")
    }

    func testArchivedReleaseNotesParseInEachLanguage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (language, name) in [
            ("en", "v1.0.8.en.md"),
            ("zh-Hans", "v1.0.8.md"),
            ("zh-Hant", "v1.0.8.zh-Hant.md")
        ] {
            let markdown = try String(
                contentsOf: root.appendingPathComponent("docs/releases/\(name)"),
                encoding: .utf8
            )
            XCTAssertNotNil(AppRemoteConfigurationService.releaseNotesSummary(markdown, language: language))
        }
    }
}
