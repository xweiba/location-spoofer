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

        let releaseNotesURLs = AppRemoteConfigurationService.releaseNotesURLs(version: "1.0.5")
        XCTAssertEqual(releaseNotesURLs.first?.host, "gh-proxy.org")
        XCTAssertEqual(releaseNotesURLs.last?.host, "raw.githubusercontent.com")
    }
}
