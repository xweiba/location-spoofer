import XCTest
@testable import PaopaoLocationSpoofer

final class AppLocalizationTests: XCTestCase {
    func testOnlyFirstPreferredLanguageSelectsTheAppLanguage() {
        XCTAssertEqual(AppLocalization.identifier(for: ["it-IT", "zh-Hans-CN"]), "en")
        XCTAssertEqual(AppLocalization.identifier(for: ["fr-FR", "zh-Hant-TW"]), "en")
        XCTAssertEqual(AppLocalization.identifier(for: ["zh-Hans-CN", "it-IT"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.identifier(for: ["zh-Hant-TW", "en-US"]), "zh-Hant")
        XCTAssertEqual(AppLocalization.identifier(for: []), "en")
    }
}
