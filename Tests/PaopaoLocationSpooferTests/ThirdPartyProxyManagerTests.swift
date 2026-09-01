import XCTest
@testable import PaopaoLocationSpoofer

@MainActor
final class ThirdPartyProxyManagerTests: XCTestCase {
    func testQueryDistinguishesConnectedWithoutCoordinate() async throws {
        let requester = FakeThirdPartyRequester(body: #"{"success":false,"error":"无已保存的坐标"}"#)
        let manager = ThirdPartyProxyManager(requester: requester)

        let response = try await manager.query()

        XCTAssertFalse(response.success)
        XCTAssertEqual(manager.connectionState, .connected(active: false))
        XCTAssertEqual(requester.lastURL?.query, "action=query")
    }

    func testSaveUsesFavoriteWGS84AndAcceptsMatchingResponse() async throws {
        let favorite = FavoriteLocation(
            name: "深圳湾",
            latitude: 22.494,
            longitude: 113.951,
            accuracy: 20,
            mapCoordinateSystem: .gcj02
        )
        let wgs84 = favorite.coordinatePair.wgs84
        let body = String(format: #"{"success":true,"longitude":%.8f,"latitude":%.8f,"accuracy":20}"#,
                          locale: Locale(identifier: "en_US_POSIX"), wgs84.longitude, wgs84.latitude)
        let requester = FakeThirdPartyRequester(body: body)
        let manager = ThirdPartyProxyManager(requester: requester)

        _ = try await manager.save(favorite)

        let components = URLComponents(url: try XCTUnwrap(requester.lastURL), resolvingAgainstBaseURL: false)
        let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let latitude = try XCTUnwrap(Double(values["lat"] ?? ""))
        let longitude = try XCTUnwrap(Double(values["lon"] ?? ""))
        XCTAssertEqual(latitude, wgs84.latitude, accuracy: 0.000_000_01)
        XCTAssertEqual(longitude, wgs84.longitude, accuracy: 0.000_000_01)
        XCTAssertEqual(values["acc"], "20")
        XCTAssertEqual(values["motion"], "0")
        XCTAssertEqual(manager.connectionState, .connected(active: true))
    }

    func testVersionEndpointRequiresProtocolAndCapabilities() async throws {
        let requester = FakeThirdPartyRequester(body: #"{"success":false,"error":"无已保存的坐标"}"#)
        let manager = ThirdPartyProxyManager(requester: requester)

        let version = try await manager.validateVersion()

        XCTAssertEqual(requester.lastURL?.path, "/wloc-settings/version")
        XCTAssertEqual(version.moduleVersion, "1.0.0")
        XCTAssertTrue(version.isCompatible)
    }

    func testConnectionUsesLegacySaveQueryEndpoint() async throws {
        let requester = FakeThirdPartyRequester(body: #"{"success":false,"error":"无已保存的坐标"}"#)
        let manager = ThirdPartyProxyManager(requester: requester)

        let response = try await manager.validateConnection()

        XCTAssertFalse(response.success)
        XCTAssertFalse(manager.moduleUpdateRecommended)
        XCTAssertEqual(requester.requestedURLs.map(\.path), ["/wloc-settings/save"])
        XCTAssertEqual(requester.requestedURLs.first?.query, "action=query")
    }

    func testMissingVersionDisablesOnlyAdvancedFeatures() async {
        let requester = FakeThirdPartyRequester(
            body: #"{"success":false,"error":"无已保存的坐标"}"#,
            versionBody: "not-json"
        )
        let manager = ThirdPartyProxyManager(requester: requester)

        let isAvailable = await manager.refreshAdvancedFeatureAvailability()

        XCTAssertFalse(isAvailable)
        XCTAssertTrue(manager.moduleUpdateRecommended)
        XCTAssertEqual(manager.connectionState, .unknown)
        XCTAssertEqual(requester.requestedURLs.map(\.path), ["/wloc-settings/version"])
    }

    func testLegacyModuleCanStillSaveBasicCoordinates() async throws {
        let favorite = FavoriteLocation(
            name: "深圳湾",
            latitude: 22.494,
            longitude: 113.951,
            accuracy: 20,
            mapCoordinateSystem: .gcj02
        )
        let wgs84 = favorite.coordinatePair.wgs84
        let body = String(
            format: #"{"success":true,"longitude":%.8f,"latitude":%.8f,"accuracy":20}"#,
            locale: Locale(identifier: "en_US_POSIX"),
            wgs84.longitude,
            wgs84.latitude
        )
        let requester = FakeThirdPartyRequester(body: body, versionBody: "not-json")
        let manager = ThirdPartyProxyManager(requester: requester)

        let response = try await manager.save(favorite)

        XCTAssertTrue(response.success)
        XCTAssertFalse(manager.moduleUpdateRecommended)
        XCTAssertEqual(manager.connectionState, .connected(active: true))
        XCTAssertEqual(requester.requestedURLs.map(\.path), ["/wloc-settings/save"])
        let components = URLComponents(
            url: try XCTUnwrap(requester.requestedURLs.first),
            resolvingAgainstBaseURL: false
        )
        let names = Set((components?.queryItems ?? []).map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["lon", "lat", "acc"]))
    }

    func testBrokenSaveQueryFailsWithoutCheckingVersion() async {
        let requester = FakeThirdPartyRequester(body: "not-json")
        let manager = ThirdPartyProxyManager(requester: requester)

        do {
            _ = try await manager.validateConnection()
            XCTFail("expected interception failure")
        } catch {
            XCTAssertEqual(error as? ThirdPartyProxyError, .moduleNotIntercepted)
        }
        XCTAssertEqual(requester.requestedURLs.map(\.path), ["/wloc-settings/save"])
    }

    func testSaveRejectsCoordinateMismatchWithoutMarkingActive() async {
        let requester = FakeThirdPartyRequester(body: #"{"success":true,"longitude":1,"latitude":2,"accuracy":25}"#)
        let manager = ThirdPartyProxyManager(requester: requester)
        let favorite = FavoriteLocation(name: "深圳湾", latitude: 22.494, longitude: 113.951, accuracy: 25)

        do {
            _ = try await manager.save(favorite)
            XCTFail("expected coordinate mismatch")
        } catch {
            XCTAssertEqual(error as? ThirdPartyProxyError, .coordinateMismatch)
        }
        XCTAssertEqual(manager.connectionState, .unknown)
        XCTAssertNil(manager.activeSettings)
    }

    func testMalformedResponseIsNotTreatedAsSuccess() async {
        let manager = ThirdPartyProxyManager(requester: FakeThirdPartyRequester(body: "not-json"))
        do {
            _ = try await manager.query()
            XCTFail("expected interception failure")
        } catch {
            XCTAssertEqual(error as? ThirdPartyProxyError, .moduleNotIntercepted)
        }
    }

    func testClientLinksUseProjectOwnedMirrorModulesAndVerificationLabels() {
        XCTAssertEqual(
            ThirdPartyProxyManager.interceptionHostnamesText,
            "gs-loc.apple.com, gs-loc-cn.apple.com"
        )
        XCTAssertNil(ThirdPartyProxyClient.shadowrocket.verificationText)
        XCTAssertTrue(ThirdPartyProxyClient.surge.verificationText?.contains("尚未验证") == true)
        XCTAssertEqual(ThirdPartyProxyClient.egern.subscriptionURL, ThirdPartyProxyClient.surge.subscriptionURL)
        XCTAssertTrue(ThirdPartyProxyClient.stash.subscriptionURL.absoluteString.hasPrefix(
            "https://gh-proxy.org/https://raw.githubusercontent.com/xweiba/location-spoofer/main/"
        ))
        let stashComponents = URLComponents(
            url: ThirdPartyProxyClient.stash.subscriptionURL,
            resolvingAgainstBaseURL: false
        )
        let shadowrocketComponents = URLComponents(
            url: ThirdPartyProxyClient.shadowrocket.subscriptionURL,
            resolvingAgainstBaseURL: false
        )
        XCTAssertEqual(stashComponents?.path, "/https://raw.githubusercontent.com/xweiba/location-spoofer/main/Resources/ThirdPartyProxyModules/wloc.stoverride")
        XCTAssertEqual(shadowrocketComponents?.path, "/https://raw.githubusercontent.com/xweiba/location-spoofer/main/Resources/ThirdPartyProxyModules/wloc.module")
        XCTAssertEqual(stashComponents?.queryItems?.first?.value, ThirdPartyProxyClient.moduleSubscriptionVersion)
        XCTAssertEqual(shadowrocketComponents?.queryItems?.first?.value, ThirdPartyProxyClient.moduleSubscriptionVersion)
        XCTAssertEqual(ThirdPartyProxyClient.shadowrocket.launchURL?.scheme, "shadowrocket")
        XCTAssertEqual(ThirdPartyProxyClient.surge.launchURL?.scheme, "surge")
        XCTAssertEqual(ThirdPartyProxyClient.quantumultX.launchURL?.scheme, "quantumult-x")
        XCTAssertEqual(ThirdPartyProxyClient.loon.launchURL?.scheme, "loon")
        XCTAssertEqual(ThirdPartyProxyClient.stash.launchURL?.scheme, "stash")
        XCTAssertEqual(ThirdPartyProxyClient.egern.launchURL?.scheme, "egern")
    }

    func testSelectedClientPersists() {
        let suiteName = "ThirdPartyProxyClientStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ThirdPartyProxyClientStore(defaults: defaults)
        XCTAssertEqual(store.selectedClient, .shadowrocket)

        store.select(.stash)
        XCTAssertEqual(ThirdPartyProxyClientStore(defaults: defaults).selectedClient, .stash)
    }
}

private final class FakeThirdPartyRequester: ThirdPartyProxyRequesting {
    private let data: Data
    private let versionData: Data
    private(set) var lastURL: URL?
    private(set) var requestedURLs: [URL] = []

    init(
        body: String,
        versionBody: String = #"{"success":true,"moduleVersion":"1.0.0","protocolVersion":1,"capabilities":["wifi","cellTower","arpc","marker","synthetic","bare","motionSimulation"]}"#
    ) {
        data = Data(body.utf8)
        versionData = Data(versionBody.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastURL = request.url
        requestedURLs.append(request.url!)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (request.url?.path == "/wloc-settings/version" ? versionData : data, response)
    }
}
