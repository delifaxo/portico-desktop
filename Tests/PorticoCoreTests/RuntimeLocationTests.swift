import Foundation
import XCTest
@testable import PorticoCore

final class RuntimeLocationTests: XCTestCase {
    private var temporaryURL: URL!
    private var appURL: URL!
    private var stableReference: String { "portico-bundled://" + RuntimeCatalog.wine.id }

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("PorticoLocationTests-" + UUID().uuidString, isDirectory: true)
        appURL = temporaryURL.appendingPathComponent("Original/Portico.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryURL { try FileManager.default.removeItem(at: temporaryURL) }
    }

    private func manifest(id: String? = nil, version: String? = nil) -> BundledRuntimeManifest {
        BundledRuntimeManifest(id: id ?? RuntimeCatalog.wine.id, name: "Wine Stable",
                               version: version ?? RuntimeCatalog.wine.version,
                               architecture: "x86_64", license: "LGPL-2.1-or-later",
                               sourceURL: RuntimeCatalog.wine.sourceURL.absoluteString,
                               components: ["GStreamer": RuntimeCatalog.gstreamerVersion], developmentOnly: true)
    }

    private func writeManifest(_ value: BundledRuntimeManifest) throws {
        let file = appURL.appendingPathComponent("Contents/Resources/RuntimeManifest.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file)
    }

    @discardableResult
    private func createRuntime() throws -> URL {
        let wine = appURL.appendingPathComponent("Contents/Frameworks/WineRuntime/bin/wine")
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        for file in [wine, wine.deletingLastPathComponent().appendingPathComponent("wineserver")] {
            // These inert fixtures are never run; validation only reads metadata and permission bits.
            try Data("runtime fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: file.path)
        }
        try writeManifest(manifest())
        return wine
    }

    func testManifestRoundTripAndOptionalFields() throws {
        try writeManifest(manifest())
        XCTAssertEqual(try BundledRuntimeManifest.load(bundleURL: appURL), manifest())
        let minimal = BundledRuntimeManifest(id: RuntimeCatalog.wine.id, name: "Wine", version: RuntimeCatalog.wine.version)
        try writeManifest(minimal)
        XCTAssertEqual(try BundledRuntimeManifest.load(bundleURL: appURL), minimal)
    }

    func testMissingManifestIsOptionalButMalformedManifestIsError() throws {
        XCTAssertNil(try BundledRuntimeManifest.load(bundleURL: appURL))
        let file = appURL.appendingPathComponent("Contents/Resources/RuntimeManifest.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for contents in ["{bad JSON", "{\"id\":\"wine\"}", "{\"id\":\"\",\"name\":\"Wine\",\"version\":\"11\"}"] {
            try Data(contents.utf8).write(to: file)
            XCTAssertThrowsError(try BundledRuntimeManifest.load(bundleURL: appURL))
        }
    }

    func testBundledExecutableEncodesItsStableIdentity() throws {
        let wine = try createRuntime()
        XCTAssertEqual(try RuntimeLocation.reference(for: wine, bundleURL: appURL), stableReference)
        XCTAssertEqual(try RuntimeLocation.resolve(reference: stableReference, bundleURL: appURL), wine)
    }

    func testPersistedBottleAndSettingsResolveAfterApplicationRelocation() throws {
        let originalWine = try createRuntime()
        let reference = try RuntimeLocation.reference(for: originalWine, bundleURL: appURL)
        let store = try LibraryStore(rootURL: temporaryURL.appendingPathComponent("Application Support/Portico"))
        let bottle = Bottle(name: "Divinity", status: .ready, enginePath: reference)
        try store.save(Library(bottles: [bottle], settings: AppSettings(enginePath: reference)))
        let relocated = temporaryURL.appendingPathComponent("Applications/Portico.app", isDirectory: true)
        try FileManager.default.createDirectory(at: relocated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: appURL, to: relocated)
        let loaded = try store.load()
        let expected = relocated.appendingPathComponent("Contents/Frameworks/WineRuntime/bin/wine")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalWine.path))
        XCTAssertEqual(try RuntimeLocation.resolve(reference: loaded.bottles[0].enginePath, bundleURL: relocated), expected)
        XCTAssertEqual(try RuntimeLocation.resolve(reference: loaded.settings.enginePath, bundleURL: relocated), expected)
    }

    func testIndependentAbsoluteWinePathsRemainUnchanged() throws {
        let external = temporaryURL.appendingPathComponent("External Wine/bin/wine")
        // External references need not exist yet; WineEngine reports their launch availability.
        XCTAssertEqual(try RuntimeLocation.resolve(reference: external.path, bundleURL: appURL), external)
        XCTAssertEqual(try RuntimeLocation.reference(for: external, bundleURL: appURL), external.path)
        let lookalike = temporaryURL.appendingPathComponent("Other.app/Contents/Frameworks/WineRuntime/bin/wine")
        XCTAssertEqual(try RuntimeLocation.reference(for: lookalike, bundleURL: appURL), lookalike.path)
    }

    func testPinnedReferenceNeverFallsBackToAnotherIdentityOrVersion() throws {
        _ = try createRuntime()
        XCTAssertThrowsError(try RuntimeLocation.resolve(reference: "portico-bundled://other-release", bundleURL: appURL))
        try writeManifest(manifest(id: "other-release"))
        XCTAssertThrowsError(try RuntimeLocation.resolve(reference: stableReference, bundleURL: appURL))
        try writeManifest(manifest(version: "99.0"))
        XCTAssertThrowsError(try RuntimeLocation.resolve(reference: stableReference, bundleURL: appURL))
    }

    func testMissingManifestOrRuntimePreventsBundledResolution() throws {
        let wine = try createRuntime()
        try FileManager.default.removeItem(at: appURL.appendingPathComponent("Contents/Resources/RuntimeManifest.json"))
        XCTAssertThrowsError(try RuntimeLocation.reference(for: wine, bundleURL: appURL))
        XCTAssertThrowsError(try RuntimeLocation.resolve(reference: stableReference, bundleURL: appURL))
        try writeManifest(manifest())
        try FileManager.default.removeItem(at: wine)
        XCTAssertThrowsError(try RuntimeLocation.resolve(reference: stableReference, bundleURL: appURL))
    }

    func testMissingOrNonExecutableServerPreventsBundledResolution() throws {
        let wine = try createRuntime()
        let server = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: server.path)
        XCTAssertThrowsError(try RuntimeLocation.resolve(reference: stableReference, bundleURL: appURL))
        try FileManager.default.removeItem(at: server)
        XCTAssertThrowsError(try RuntimeLocation.resolve(reference: stableReference, bundleURL: appURL))
    }

    func testBundledExecutableCannotResolveThroughSymlinkOutsideApp() throws {
        let wine = try createRuntime()
        let external = temporaryURL.appendingPathComponent("external-wine")
        try FileManager.default.moveItem(at: wine, to: external)
        try FileManager.default.createSymbolicLink(at: wine, withDestinationURL: external)
        XCTAssertThrowsError(try RuntimeLocation.resolve(reference: stableReference, bundleURL: appURL))
        XCTAssertThrowsError(try RuntimeLocation.reference(for: wine, bundleURL: appURL))
    }

    func testManifestCannotResolveOutsideApplication() throws {
        _ = try createRuntime()
        let file = appURL.appendingPathComponent("Contents/Resources/RuntimeManifest.json")
        let external = temporaryURL.appendingPathComponent("external-manifest.json")
        try FileManager.default.moveItem(at: file, to: external)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        XCTAssertThrowsError(try BundledRuntimeManifest.load(bundleURL: appURL))
        XCTAssertThrowsError(try RuntimeLocation.resolve(reference: stableReference, bundleURL: appURL))
    }

    func testMalformedReferenceCannotOverrideBundledExecutablePath() throws {
        _ = try createRuntime()
        for reference in [stableReference + "/../other", stableReference + "?path=/bin/sh", stableReference + "#other",
                          "wine", "~/bin/wine", "https://example.com/wine"] {
            XCTAssertThrowsError(try RuntimeLocation.resolve(reference: reference, bundleURL: appURL))
        }
        XCTAssertThrowsError(try RuntimeLocation.reference(for: URL(string: "https://example.com/wine")!, bundleURL: appURL))
    }
}
