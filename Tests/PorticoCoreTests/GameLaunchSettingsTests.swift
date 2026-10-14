import Foundation
import XCTest
@testable import PorticoCore

final class GameLaunchSettingsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Portico Routes \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ path: URL, _ text: String = "fixture") throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
    }
    private func installSteam(_ prefix: URL, id: String = "1771300") throws -> URL {
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try file(steam.appendingPathComponent("steam.exe"))
        try file(steam.appendingPathComponent("steamapps/appmanifest_\(id).acf"),
            "\"AppState\" { \"appid\" \"\(id)\" \"name\" \"Test game\" \"installdir\" \"Test game\" \"StateFlags\" \"4\" }")
        try file(steam.appendingPathComponent("steamapps/common/Test game/Game.exe"))
        return steam
    }
    private func bottle() -> Bottle { Bottle(name: "Selected environment", status: .ready, enginePath: "/test/wine") }

    func testSteamSwitchResolvesDestinationAndPreservesCardIdentity() throws {
        let source = try installSteam(root.appendingPathComponent("source"))
        let prefix = root.appendingPathComponent("destination")
        let target = try installSteam(prefix)
        let selected = bottle()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let game = Game(name: "My game", bottleID: UUID(), executablePath: source.appendingPathComponent("steam.exe").path,
                        addedAt: date, lastPlayedAt: date, isFavorite: true, steamAppID: "1771300")
        let updated = try game.selectingLaunch(method: .steam, bottle: selected, prefix: prefix, appID: "001771300",
            executable: game.executablePath, arguments: ["old argument"], directory: source.path, crossOver: nil)
        XCTAssertEqual(updated.bottleID, selected.id)
        XCTAssertEqual(updated.executablePath, target.appendingPathComponent("steam.exe").path)
        XCTAssertEqual(updated.workingDirectory, target.appendingPathComponent("steamapps/common/Test game").path)
        XCTAssertEqual(updated.arguments, [])
        XCTAssertEqual(updated.steamAppID, "1771300")
        XCTAssertEqual(updated.id, game.id)
        XCTAssertEqual(updated.addedAt, date)
        XCTAssertEqual(updated.lastPlayedAt, date)
        XCTAssertTrue(updated.isFavorite)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("steamapps/common/Test game/Game.exe")), "fixture")
    }

    func testSteamSwitchRequiresBothClientAndInstalledGame() throws {
        let selected = bottle(), prefix = root.appendingPathComponent("destination")
        let game = Game(name: "Game", bottleID: selected.id, executablePath: "/old/steam.exe", steamAppID: "1771300")
        func select(_ id: String) throws -> Game {
            try game.selectingLaunch(method: .steam, bottle: selected, prefix: prefix, appID: id,
                executable: game.executablePath, arguments: [], directory: nil, crossOver: nil)
        }
        XCTAssertThrowsError(try select("1771300"))
        _ = try installSteam(prefix, id: "42")
        XCTAssertThrowsError(try select("1771300"))
        XCTAssertThrowsError(try select("42/extra"))
        XCTAssertEqual(try select("42").steamAppID, "42")
    }

    func testDirectRouteRetainsSteamIdentityButRejectsClientAsGameExecutable() throws {
        let selected = bottle(), prefix = root.appendingPathComponent("prefix")
        let steam = try installSteam(prefix)
        let executable = steam.appendingPathComponent("steamapps/common/Test game/Game.exe")
        let game = Game(name: "Game", bottleID: selected.id, executablePath: steam.appendingPathComponent("steam.exe").path,
                        steamAppID: "1771300")
        XCTAssertThrowsError(try game.selectingLaunch(method: .executable, bottle: selected, prefix: prefix, appID: "1771300",
            executable: game.executablePath, arguments: [], directory: nil, crossOver: nil))
        let updated = try game.selectingLaunch(method: .executable, bottle: selected, prefix: prefix, appID: "1771300",
            executable: executable.path, arguments: ["a literal argument"], directory: executable.deletingLastPathComponent().path, crossOver: nil)
        XCTAssertEqual(updated.effectiveLaunchMethod, .executable)
        XCTAssertEqual(updated.steamAppID, "1771300")
        XCTAssertEqual(updated.arguments, ["a literal argument"])
        XCTAssertEqual(updated.id, game.id)
    }

    func testCrossOverSelectionIsAnExternalRouteAndPersistsPorticoProfile() throws {
        guard !DistributionPolicy.isAppStore else { throw XCTSkip("External launch disabled") }
        let shortcut = root.appendingPathComponent("Existing Game.app")
        let executable = shortcut.appendingPathComponent("Contents/MacOS/Menu Helper")
        try file(executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = ["CFBundleIdentifier": "com.codeweavers.CrossOverHelper.test", "CFBundleExecutable": "Menu Helper",
                     "CFBundleName": "Existing Game", "CXHelperAppBottleName": "My CrossOver bottle", "CrossOverHelperCommand": "game.exe"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: shortcut.appendingPathComponent("Contents/Info.plist"))
        var launcher = try CrossOverSupport.game(at: shortcut)
        launcher.addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let selected = bottle()
        let original = Game(name: "My game", bottleID: selected.id, executablePath: "/old/steam.exe",
                            addedAt: Date(timeIntervalSince1970: 1_700_000_000), steamAppID: "1771300")
        let game = try original.selectingLaunch(method: .crossOver, bottle: nil, prefix: nil, appID: "",
            executable: "", arguments: [], directory: nil, crossOver: launcher)
        XCTAssertEqual(game.bottleID, original.bottleID)
        XCTAssertEqual(game.executablePath, original.executablePath)
        XCTAssertEqual(game.effectiveLaunchMethod, .crossOver)
        XCTAssertEqual(try CrossOverSupport.launchURL(for: XCTUnwrap(game.crossOverLauncher)).path, shortcut.path)
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Store"))
        try store.save(Library(bottles: [selected], games: [game]))
        XCTAssertEqual(try store.load().games[0], game)
    }

    func testLegacyCardsKeepTheirRouteAndExplicitChoiceSurvivesReload() throws {
        let selected = bottle()
        var game = Game(name: "Game", bottleID: selected.id, executablePath: "/Games/Game.exe")
        XCTAssertEqual(game.effectiveLaunchMethod, .executable)
        game.steamAppID = "42"
        XCTAssertEqual(game.effectiveLaunchMethod, .steam)
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Store"))
        try store.save(Library(bottles: [selected], games: [game]))
        XCTAssertNil(try store.load().games[0].launchMethod)
        game.launchMethod = .executable
        try store.save(Library(bottles: [selected], games: [game]))
        XCTAssertEqual(try store.load().games[0].effectiveLaunchMethod, .executable)
        XCTAssertEqual(try store.load().games[0].steamAppID, "42")
        game.launchMethod = .crossOver
        XCTAssertThrowsError(try store.save(Library(bottles: [selected], games: [game])))
        XCTAssertEqual(try store.load().games[0].effectiveLaunchMethod, .executable)
    }
}
