import XCTest
@testable import PorticoCore

final class MetalFXTests: XCTestCase {
    func testLegacyGameDefaultsOffAndPreferenceRoundTrips() throws {
        let game = Game(name: "Game", bottleID: UUID(), executablePath: "/game.exe")
        let data = try JSONEncoder().encode(game)
        let legacy = try JSONDecoder().decode(Game.self, from: data)
        XCTAssertNil(legacy.enableMetalFX)
        XCTAssertFalse(legacy.effectiveMetalFXEnabled)
        var enabled = legacy
        enabled.enableMetalFX = true
        XCTAssertTrue(try JSONDecoder().decode(Game.self, from: JSONEncoder().encode(enabled)).effectiveMetalFXEnabled)
    }

    func testOnlyManagedD3DMetalRoutesOfferMetalFX() {
        var game = Game(name: "Game", bottleID: UUID(), executablePath: "/game.exe")
        var bottle = Bottle(name: "Graphics", enginePath: "/wine",
            graphics: BottleGraphics(backend: .d3dMetal, providerID: GraphicsRuntimeCatalog.appleGPTK3.id))
        XCTAssertTrue(MetalFX.isSupported(game: game, bottle: bottle))
        game.launchMethod = .crossOver
        XCTAssertFalse(MetalFX.isSupported(game: game, bottle: bottle))
        game.launchMethod = .executable
        game.graphicsProfile = .directX9
        XCTAssertFalse(MetalFX.isSupported(game: game, bottle: bottle))
        game.graphicsProfile = .automatic
        bottle.graphics = nil
        XCTAssertFalse(MetalFX.isSupported(game: game, bottle: bottle))
    }
}
