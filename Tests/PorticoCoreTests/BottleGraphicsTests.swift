import Foundation
import XCTest
@testable import PorticoCore

final class BottleGraphicsTests: XCTestCase {
    func testLegacyLibraryWithoutGraphicsStillDecodes() throws {
        let data = Data(#"{"schemaVersion":1,"bottles":[{"id":"BD143504-8C4C-41C0-9B52-033DAA680CE0","name":"Divinity","createdAt":"2026-09-06T00:00:00Z","status":"ready","enginePath":"/external/wine"}],"games":[],"settings":{"enginePath":"/external/wine","verboseLogging":false}}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(Library.self, from: data)
        XCTAssertNil(library.bottles[0].graphics)
        XCTAssertEqual(library.bottles[0].enginePath, "/external/wine")
        XCTAssertEqual(library.schemaVersion, 1)
    }

    func testExistingBottleInitializerKeepsGraphicsUnspecified() {
        let bottle = Bottle(name: "Existing setup", enginePath: "/external/wine")
        XCTAssertNil(bottle.graphics)
    }

    func testGraphicsSelectionRoundTripsWithPinnedIdentity() throws {
        let graphics = BottleGraphics(backend: .d3dMetal, providerID: GraphicsRuntimeCatalog.appleGPTK3.id)
        let bottle = Bottle(name: "Gothic", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                            status: .ready, enginePath: "portico-bundled://wine-stable-11.0_1", graphics: graphics)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bottle)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Bottle.self, from: data), bottle)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let savedGraphics = try XCTUnwrap(json["graphics"] as? [String: Any])
        XCTAssertEqual(savedGraphics["backend"] as? String, "d3dMetal")
        XCTAssertEqual(savedGraphics["providerID"] as? String, "gptk-3.0-3")
    }

    func testDefaultWineNeedsNoProvider() throws {
        let graphics = BottleGraphics()
        XCTAssertEqual(graphics.backend, .wineDefault)
        XCTAssertNil(graphics.providerID)
        XCTAssertNoThrow(try graphics.validate())
        XCTAssertEqual(try JSONDecoder().decode(BottleGraphics.self, from: Data(#"{"backend":"wineDefault"}"#.utf8)), graphics)
    }

    func testKnownD3DMetalProviderPassesIdentityValidation() throws {
        XCTAssertNoThrow(try BottleGraphics(backend: .d3dMetal, providerID: GraphicsRuntimeCatalog.appleGPTK3.id).validate())
    }

    func testD3DMetalRejectsMissingUnknownAndPathLikeProviderIDs() throws {
        let invalidIDs: [String?] = [nil, "", "unknown-provider", "gptk-99.0", "../gptk-3.0-3",
                                     "/Applications/D3DMetal.framework", "file:///tmp/provider", "gptk-3.0-3\n"]
        for providerID in invalidIDs {
            XCTAssertThrowsError(try BottleGraphics(backend: .d3dMetal, providerID: providerID).validate())
        }
    }

    func testDefaultWineCannotRetainAnActiveSeparateProvider() throws {
        XCTAssertThrowsError(try BottleGraphics(backend: .wineDefault, providerID: GraphicsRuntimeCatalog.appleGPTK3.id).validate())
    }

    func testUnknownBackendFailsDecodingInsteadOfSilentlyChangingGraphics() throws {
        let data = Data(#"{"backend":"futureBackend","providerID":"gptk-3.0-3"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BottleGraphics.self, from: data))
    }

}
