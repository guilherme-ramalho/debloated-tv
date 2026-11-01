import XCTest
@testable import TVRemoteCore

/// The TV tab's knowledge per TV (TESTING.md: SET-*), and the address and model-request helpers.
@MainActor final class TVSetupStateTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "tvsetup-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testUnknownTVStartsUncheckedAndNotInstalled() {
        let info = TVSetupStatus(defaults: defaults()).info("192.168.0.13")
        XCTAssertFalse(info.homeInstalled)
        XCTAssertNil(info.supported, "the badge must say 'Check if my TV is supported' until a setup read the model")
    }

    func testStatePersistsPerTVAndUndoResetsIt() {
        let d = defaults()
        let status = TVSetupStatus(defaults: d)
        status.sawHome("192.168.0.13")
        status.update("192.168.0.13") { $0.disabledCount = 35 }
        let reopened = TVSetupStatus(defaults: d)
        XCTAssertTrue(reopened.info("192.168.0.13").homeInstalled)
        XCTAssertEqual(reopened.info("192.168.0.13").disabledCount, 35)
        XCTAssertFalse(reopened.info("192.168.0.14").homeInstalled, "another TV is unaffected")
        reopened.restored("192.168.0.13")
        XCTAssertFalse(reopened.info("192.168.0.13").homeInstalled)
        XCTAssertNil(reopened.info("192.168.0.13").disabledCount)
    }

    func testEmptyHostIsIgnored() {
        let status = TVSetupStatus(defaults: defaults())
        status.sawHome("")
        XCTAssertFalse(status.info("").homeInstalled)
    }

    func testInspectionNamesTheTVWithoutRepeatingTheBrand() {
        let status = TVSetupStatus(defaults: defaults())
        status.inspected("a", properties: ["ro.product.manufacturer": "TCL", "ro.product.model": "Smart TV Pro",
                                           "ro.product.device": "BeyondTV4", "ro.build.version.release": "11"], profile: nil)
        XCTAssertEqual(status.info("a").model, "TCL Smart TV Pro")
        XCTAssertEqual(status.info("a").detail, "BeyondTV4 · Android 11")
        XCTAssertEqual(status.info("a").supported, false)
        status.inspected("b", properties: ["ro.product.manufacturer": "Sony", "ro.product.model": "Sony BRAVIA 4K"], profile: nil)
        XCTAssertEqual(status.info("b").model, "Sony BRAVIA 4K")
        status.inspected("c", properties: [:], profile: nil)
        XCTAssertEqual(status.info("c").model, "Unknown model")
        XCTAssertEqual(status.info("c").detail, "")
    }

    func testOfferAppearsOnceWhenTheTVShowsAStockHome() async throws {
        let status = TVSetupStatus(defaults: defaults(), offerDelay: .zero)
        status.offerAfterPairing("tv", showing: "com.google.android.apps.tv.launcherx")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(status.offerFor, "tv")
        status.offerFor = nil
        status.offerAfterPairing("tv", showing: "com.google.android.apps.tv.launcherx")
        status.sawForeground("tv", "com.google.android.tvlauncher")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(status.offerFor, "only once per TV")
    }

    func testOfferWaitsWhileAnAppIsOnScreen() async throws {
        let status = TVSetupStatus(defaults: defaults(), offerDelay: .zero)
        status.offerAfterPairing("tv", showing: "com.netflix.ninja")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(status.offerFor, "nothing is known while Netflix plays")
        status.sawForeground("tv", "com.google.android.youtube.tv")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(status.offerFor)
        status.sawForeground("tv", "com.google.android.tvlauncher")   // the user pressed Home
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(status.offerFor, "tv")
    }

    func testNoOfferWhenTheTVShowsTheNewHome() async throws {
        let status = TVSetupStatus(defaults: defaults(), offerDelay: .zero)
        status.offerAfterPairing("tv", showing: "com.netflix.ninja")
        status.sawForeground("tv", TVSetupStatus.homePackage)
        status.sawForeground("tv", "com.google.android.tvlauncher")   // e.g. after an undo, later
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(status.offerFor)
        XCTAssertTrue(status.info("tv").homeInstalled)
        let already = TVSetupStatus(defaults: defaults(), offerDelay: .zero)
        already.sawHome("tv2")
        already.offerAfterPairing("tv2", showing: "com.google.android.tvlauncher")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(already.offerFor)
    }

    func testLauncherNames() {
        XCTAssertTrue(TVSetupStatus.isLauncher("com.google.android.apps.tv.launcherx"))
        XCTAssertTrue(TVSetupStatus.isLauncher("com.mitv.tvhome"))
        XCTAssertTrue(TVSetupStatus.isLauncher("com.sony.dtv.home"))
        XCTAssertFalse(TVSetupStatus.isLauncher("com.netflix.ninja"))
        XCTAssertFalse(TVSetupStatus.isLauncher("com.tcl.tv"))
    }

    func testTVAddressParsing() {
        XCTAssertEqual(TVAddress("192.168.0.13")?.port, 5555)
        XCTAssertEqual(TVAddress(" 192.168.0.13 ")?.host, "192.168.0.13")
        XCTAssertEqual(TVAddress("192.168.0.11:15555")?.port, 15555)
        XCTAssertEqual(TVAddress("Mac.local:15555")?.host, "Mac.local")
        for bad in ["", ":5555", "a:b:c", "tv:0", "tv:70000", "tv:", "my tv", "tv:abc"] {
            XCTAssertNil(TVAddress(bad), bad)
        }
    }

    func testTypedAddressesAcceptRegionalKeyboards() {
        XCTAssertEqual(TVAddress.typed("192,168,0,13"), "192.168.0.13", "comma keyboards (Spain, Brazil…)")
        XCTAssertEqual(TVAddress.typed(" 192.168.0.13 "), "192.168.0.13")
        XCTAssertTrue(TVAddress.isIPv4("192.168.0.13"))
        for bad in ["192.168.0", "192.168.0.256", "a.b.c.d", "192.168..13", "1.2.3.4.5", "١٢.١.١.١", ""] {
            XCTAssertFalse(TVAddress.isIPv4(bad), bad)
        }
    }

    func testModelRequestCarriesOnlyModelDetailsAndNeedsHTTPS() throws {
        let info = TVSetupInfo(supported: false, model: "Acme TV", detail: "acme1 · Android 12")
        XCTAssertNil(ModelRequest.url(info, form: nil))
        XCTAssertNil(ModelRequest.url(info, form: "http://forms.example/x"), "never send over plain HTTP")
        let url = try XCTUnwrap(ModelRequest.url(info, form: "https://forms.example/x?usp=pp_url"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "model" }?.value, "Acme TV")
        XCTAssertEqual(items.first { $0.name == "usp" }?.value, "pp_url", "keeps the form's own parameters")
        XCTAssertTrue(ModelRequest.text(info).contains("Acme TV"))
        XCTAssertFalse(ModelRequest.text(info).contains("192.168"), "no address or other personal data")
    }
}
