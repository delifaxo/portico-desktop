import XCTest
@testable import PorticoCore

final class GameRemovalTests: XCTestCase {
    private var root: URL!
    private var store: LibraryStore!
    private var game: Game!
    private var library: Library!
    private var folder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PorticoRemoval-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        store = try LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let bottle = Bottle(name: "Test", createdAt: date, status: .ready, enginePath: "/opt/wine/bin/wine")
        folder = store.prefixURL(for: bottle).appendingPathComponent("drive_c/Games/Chosen Game")
        let executable = folder.appendingPathComponent("bin/game.exe")
        try file(executable)
        game = Game(name: "Chosen Game", bottleID: bottle.id, executablePath: executable.path, addedAt: date)
        library = Library(bottles: [bottle], games: [game])
        try store.save(library)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func file(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }

    private func validate(_ url: URL) throws -> URL {
        try GameRemoval.validatedFolder(url, for: game, in: library, libraryRoot: store.rootURL, home: root.appendingPathComponent("Home"))
    }

    func testAcceptsExplicitGameFolderAndDoesNotMutateAnything() throws {
        let before = try Data(contentsOf: store.libraryURL)
        XCTAssertEqual(try validate(folder).path, folder.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.executablePath))
        XCTAssertEqual(try Data(contentsOf: store.libraryURL), before)
        let external = root.appendingPathComponent("External/Portable Game")
        try file(external.appendingPathComponent("game.exe"))
        game.executablePath = external.appendingPathComponent("game.exe").path
        library.games = [game]
        XCTAssertEqual(try validate(external).path, external.path)
    }

    func testRejectsPrefixWindowsAndSharedLibraryRoots() throws {
        let prefix = store.prefixURL(for: library.bottles[0])
        for path in [root!, store.rootURL, prefix, prefix.appendingPathComponent("drive_c"), folder.deletingLastPathComponent()] {
            XCTAssertThrowsError(try validate(path), path.path)
        }
        for name in ["Windows", "Users", "ProgramData", "Program Files", "Program Files (x86)", "Steam", "steamapps", "common"] {
            let shared = prefix.appendingPathComponent("drive_c/\(name)")
            let executable = shared.appendingPathComponent("game.exe")
            try file(executable)
            game.executablePath = executable.path
            library.games = [game]
            XCTAssertThrowsError(try validate(shared), name)
        }
    }

    func testRejectsSymlinkFolderAndExecutableEscapingFolder() throws {
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        XCTAssertThrowsError(try validate(alias))
        let external = root.appendingPathComponent("outside.exe")
        try file(external)
        let link = folder.appendingPathComponent("linked.exe")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        game.executablePath = link.path
        library.games = [game]
        XCTAssertThrowsError(try validate(folder))
    }

    func testRejectsOtherGamesAndProfilesSharingTheFolder() throws {
        let otherPath = folder.appendingPathComponent("other/game.exe")
        try file(otherPath)
        var other = Game(name: "Other game", bottleID: game.bottleID, executablePath: otherPath.path)
        library.games.append(other)
        XCTAssertThrowsError(try validate(folder))
        other.executablePath = game.executablePath
        library.games = [game, other]
        XCTAssertThrowsError(try validate(folder))
        other.executablePath = root.appendingPathComponent("other.exe").path
        other.workingDirectory = folder.path
        library.games = [game, other]
        XCTAssertThrowsError(try validate(folder))
    }

    func testPathPrefixDoesNotConfuseSiblingFolders() throws {
        let sibling = URL(fileURLWithPath: folder.path + " 2/game.exe")
        try file(sibling)
        library.games.append(Game(name: "Sibling", bottleID: game.bottleID, executablePath: sibling.path))
        XCTAssertEqual(try validate(folder).path, folder.path)
        XCTAssertThrowsError(try validate(sibling.deletingLastPathComponent()))
    }

    func testRejectsSteamCrossOverAndStaleGameMetadata() throws {
        game.steamAppID = "42"
        library.games = [game]
        XCTAssertThrowsError(try validate(folder))
        game.steamAppID = nil
        game.launchMethod = .crossOver
        library.games = [game]
        XCTAssertThrowsError(try validate(folder))
        game.launchMethod = .executable
        library.games = []
        XCTAssertThrowsError(try validate(folder))
    }

    func testRejectsHomeFoldersAndRuntimeBundles() throws {
        let home = root.appendingPathComponent("Home")
        for name in ["Documents", "Downloads", "Desktop", "Applications", "Library"] {
            let broad = home.appendingPathComponent(name)
            try file(broad.appendingPathComponent("game.exe"))
            game.executablePath = broad.appendingPathComponent("game.exe").path
            library.games = [game]
            XCTAssertThrowsError(try validate(broad))
        }
        let bundled = root.appendingPathComponent("Runtime.app/Contents/Game")
        try file(bundled.appendingPathComponent("game.exe"))
        game.executablePath = bundled.appendingPathComponent("game.exe").path
        library.games = [game]
        XCTAssertThrowsError(try validate(bundled))
    }

    func testRemovingOneLibraryEntryPreservesGameFilesSavesAndOtherEntries() throws {
        let save = folder.appendingPathComponent("save.dat")
        try file(save)
        let other = Game(name: "Other", bottleID: game.bottleID, executablePath: "/Games/other.exe", addedAt: game.addedAt)
        let crossOver = CrossOverGame(name: "External", launcherPath: "/Applications/Game.app", bottleName: "External", addedAt: game.addedAt)
        library.games.append(other)
        library.crossOverGames = [crossOver]
        let bottles = library.bottles
        library.games.removeAll { $0.id == game.id }
        try store.save(library)
        let loaded = try store.load()
        XCTAssertEqual(loaded.games, [other])
        XCTAssertEqual(loaded.crossOverGames, [crossOver])
        XCTAssertEqual(loaded.bottles, bottles)
        XCTAssertEqual(try String(contentsOf: save, encoding: .utf8), "fixture")
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.executablePath))
    }

    func testSteamUninstallUsesValidatedLiteralAppID() throws {
        XCTAssertEqual(try SteamAction.uninstall(appID: "00042").uri, "steam://uninstall/42")
        for invalid in ["", "0", "-1", "1/../2", "1;rm", "4294967296"] {
            XCTAssertThrowsError(try SteamAction.uninstall(appID: invalid).uri)
        }
    }
}
