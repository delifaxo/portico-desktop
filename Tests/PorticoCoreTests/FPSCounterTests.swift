import XCTest
@testable import PorticoCore

final class FPSCounterTests: XCTestCase {
    func testOlderSettingsDefaultToHiddenAndRoundTrip() throws {
        let old = Data(#"{"enginePath":"/wine","verboseLogging":true}"#.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertFalse(settings.showFPS)
        settings.showFPS = true
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
    }
    func testPerLaunchToggleOverridesInheritedValueWithoutChangingOtherVariables() {
        let inherited = ["MTL_HUD_ENABLED": "1", "WINEPREFIX": "/game", "OTHER": "literal value"]
        let hidden = FPSCounter.applying(enabled: false, to: inherited)
        XCTAssertEqual(hidden["MTL_HUD_ENABLED"], "0")
        XCTAssertEqual(hidden["WINEPREFIX"], "/game")
        XCTAssertEqual(hidden["OTHER"], "literal value")
        XCTAssertEqual(inherited["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(FPSCounter.applying(enabled: true, to: hidden)["MTL_HUD_ENABLED"], "1")
    }
}
