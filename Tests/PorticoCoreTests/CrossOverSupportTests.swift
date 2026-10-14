import Foundation
import XCTest
@testable import PorticoCore

final class CrossOverSupportTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PorticoCrossOverTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryURL { try FileManager.default.removeItem(at: temporaryURL) }
    }

    private func requireDirectDistribution() throws {
        if DistributionPolicy.isAppStore { throw XCTSkip("External CrossOver is disabled in the App Store profile.") }
    }

    @discardableResult
    private func makeLauncher(_ relativePath: String = "Steam/Gothic 1 Remake.app", name: String = "Gothic 1 Remake",
                              bottle: String = "Steam", changes: [String: Any] = [:],
                              format: PropertyListSerialization.PropertyListFormat = .xml) throws -> URL {
        let launcher = temporaryURL.appendingPathComponent(relativePath, isDirectory: true)
        let executable = launcher.appendingPathComponent("Contents/MacOS/Menu Helper")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Discovery and launchURL validation must never execute this file.
        try Data("not an executable program".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var metadata: [String: Any] = [
            "CFBundleIdentifier": "com.codeweavers.CrossOverHelper.TEST.\(UUID().uuidString)",
            "CFBundleExecutable": "Menu Helper",
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CXHelperAppBottleName": bottle,
            "CrossOverHelperCommand": "\"C:\\Games\\game.exe\""
        ]
        for (key, value) in changes { metadata[key] = value }
        try PropertyListSerialization.data(fromPropertyList: metadata, format: format, options: 0)
            .write(to: launcher.appendingPathComponent("Contents/Info.plist"))
        return launcher
    }

    func testDiscoveryRecursesAndExcludesOrdinaryMalformedAndNestedApps() throws {
        try requireDirectDistribution()
        let gothic = try makeLauncher()
        let heroes = try makeLauncher("Other/Nested/Heroes.app", name: "Heroes III", bottle: "Heroes")
        try makeLauncher("Ordinary.app", changes: ["CFBundleIdentifier": "com.example.ordinary"])
        try makeLauncher("Ordinary.app/Contents/Nested.app", name: "Nested decoy")
        try makeLauncher("Malformed.app", changes: ["CrossOverHelperCommand": " "])
        let games = CrossOverSupport.discoverGames(in: temporaryURL)
        XCTAssertEqual(games.map(\.name), ["Gothic 1 Remake", "Heroes III"])
        XCTAssertEqual(Set(games.map(\.launcherPath)), Set([gothic, heroes].map { $0.resolvingSymlinksInPath().path }))
        XCTAssertEqual(games.map(\.bottleName), ["Steam", "Heroes"])
        XCTAssertEqual(CrossOverSupport.discoverGames(in: temporaryURL.appendingPathComponent("absent")), [])
    }

    func testLauncherCommandRemainsOpaqueAndIsNotExecuted() throws {
        try requireDirectDistribution()
        let marker = temporaryURL.appendingPathComponent("should-not-exist")
        let launcher = try makeLauncher(changes: ["CrossOverHelperCommand": "$(touch '\(marker.path)'); echo untrusted"])
        let game = try CrossOverSupport.game(at: launcher)
        XCTAssertEqual(try CrossOverSupport.launchURL(for: game).path, launcher.resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDeletedOrChangedLauncherIsRejectedAtLaunchTime() throws {
        try requireDirectDistribution()
        let launcher = try makeLauncher()
        let game = try CrossOverSupport.game(at: launcher)
        try makeLauncher(bottle: "A different bottle")
        XCTAssertThrowsError(try CrossOverSupport.launchURL(for: game))
        try makeLauncher(changes: ["CFBundleExecutable": "Unrelated"])
        XCTAssertThrowsError(try CrossOverSupport.launchURL(for: game))
        try makeLauncher(changes: ["CFBundleIdentifier": "com.example.replacement"])
        XCTAssertThrowsError(try CrossOverSupport.launchURL(for: game))
        try FileManager.default.removeItem(at: launcher)
        XCTAssertThrowsError(try CrossOverSupport.launchURL(for: game))
    }

    func testMissingExecutableAndInvalidMetadataAreRejected() throws {
        try requireDirectDistribution()
        for changes: [String: Any] in [
            ["CXHelperAppBottleName": ""], ["CXHelperAppBottleName": "bad\u{0000}name"],
            ["CrossOverHelperCommand": ""], ["CrossOverHelperCommand": "bad\u{0000}command"],
            ["CFBundleName": "\n"], ["CFBundleIdentifier": "com.example.app"],
            ["CFBundleExecutable": "../Unrelated"]
        ] {
            // XML cannot encode NUL; binary fixtures reach the application's validation.
            let launcher = try makeLauncher(changes: changes, format: .binary)
            XCTAssertThrowsError(try CrossOverSupport.game(at: launcher))
        }
        let launcher = try makeLauncher()
        try FileManager.default.removeItem(at: launcher.appendingPathComponent("Contents/MacOS/Menu Helper"))
        XCTAssertThrowsError(try CrossOverSupport.game(at: launcher))
    }

    func testLegacyLibraryDecodesWithoutCrossOverField() throws {
        let store = try LibraryStore(rootURL: temporaryURL.appendingPathComponent("Store"))
        let legacy = Data("""
        {"schemaVersion":1,"bottles":[],"games":[],"settings":{"enginePath":"","verboseLogging":false}}
        """.utf8)
        try legacy.write(to: store.libraryURL)
        XCTAssertEqual(try store.load(), Library())
        XCTAssertNil(try store.load().crossOverGames)
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), legacy)
    }

    func testCrossOverReferencesRoundTripEvenWhenExternalAppIsAbsent() throws {
        let store = try LibraryStore(rootURL: temporaryURL.appendingPathComponent("Store"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let game = CrossOverGame(name: "Gothic 1 Remake", launcherPath: "/External/Steam/Gothic.app", bottleName: "Steam",
                                 addedAt: date, lastPlayedAt: date, isFavorite: true)
        let library = Library(crossOverGames: [game])
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
    }

    func testDuplicateAndInvalidReferencesCannotReplaceSavedLibrary() throws {
        let store = try LibraryStore(rootURL: temporaryURL.appendingPathComponent("Store"))
        let game = CrossOverGame(name: "Gothic 1 Remake", launcherPath: "/External/Steam/Gothic.app", bottleName: "Steam",
                                 addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let library = Library(crossOverGames: [game])
        try store.save(library)
        let original = try Data(contentsOf: store.libraryURL)
        var duplicateID = game
        duplicateID.launcherPath = "/External/Steam/Another.app"
        XCTAssertThrowsError(try store.save(Library(crossOverGames: [game, duplicateID])))
        var duplicatePath = game
        duplicatePath.id = UUID()
        duplicatePath.launcherPath = "/External/Steam/Other/../Gothic.app"
        XCTAssertThrowsError(try store.save(Library(crossOverGames: [game, duplicatePath])))
        for invalidPath in ["relative/Game.app", "/External/Game.exe", "/External/Bad\u{0000}Game.app"] {
            var invalid = game
            invalid.launcherPath = invalidPath
            XCTAssertThrowsError(try store.save(Library(crossOverGames: [invalid])))
        }
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), original)
        XCTAssertEqual(try store.load(), library)
    }

    func testAppStoreProfileDisablesExternalCrossOver() throws {
        guard DistributionPolicy.isAppStore else { return }
        let launcher = try makeLauncher()
        XCTAssertEqual(CrossOverSupport.discoverGames(in: temporaryURL), [])
        XCTAssertThrowsError(try CrossOverSupport.game(at: launcher))
        let game = CrossOverGame(name: "Gothic", launcherPath: launcher.path, bottleName: "Steam")
        XCTAssertThrowsError(try CrossOverSupport.launchURL(for: game))
    }
}
