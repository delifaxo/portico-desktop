import XCTest
@testable import PorticoCore

final class GameGraphicsTests: XCTestCase {
    private var root: URL!
    private var prefix: URL { root.appendingPathComponent("prefix") }
    private var gameFolder: URL { prefix.appendingPathComponent("drive_c/Games/Arbitrary game") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Portico Graphics \(UUID())").resolvingSymlinksInPath()
        try file(gameFolder.appendingPathComponent("Unknown title.exe"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func file(_ url: URL, _ text: String = "fixture") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func game() -> Game {
        var game = Game(name: "Any Windows game", bottleID: UUID(), executablePath: gameFolder.appendingPathComponent("Unknown title.exe").path)
        game.graphicsProfile = .directX9
        return game
    }
    private func installSteam() throws -> Game {
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try file(steam.appendingPathComponent("steam.exe"))
        try file(steam.appendingPathComponent("steamapps/appmanifest_7654321.acf"),
            #"""
            "AppState" { "appid" "7654321" "name" "Not in a known catalogue" "installdir" "Unknown" "StateFlags" "4" }
            """#)
        let folder = steam.appendingPathComponent("steamapps/common/Unknown")
        try file(folder.appendingPathComponent("UnlistedGame.exe"))
        var game = Game(name: "Unlisted Steam game", bottleID: UUID(), executablePath: steam.appendingPathComponent("steam.exe").path,
                        workingDirectory: folder.path, steamAppID: "7654321")
        game.graphicsProfile = .directX9
        return game
    }

    func testStandaloneAndUnlistedSteamGamesResolveWithoutCatalogue() throws {
        XCTAssertEqual(try GameGraphics.targetExecutable(game: game(), prefix: prefix)?.lastPathComponent, "Unknown title.exe")
        let steam = try installSteam()
        XCTAssertEqual(try GameGraphics.targetExecutable(game: steam, prefix: prefix)?.lastPathComponent, "UnlistedGame.exe")
        let folder = URL(fileURLWithPath: steam.workingDirectory!)
        try file(folder.appendingPathComponent("DirectX_Redist/DXSETUP.exe"))
        XCTAssertEqual(try GameGraphics.targetExecutable(game: steam, prefix: prefix)?.lastPathComponent, "UnlistedGame.exe")
    }

    func testAmbiguousSteamGameRequiresSelectionAndCannotTargetAnotherGame() throws {
        var steam = try installSteam()
        let folder = URL(fileURLWithPath: steam.workingDirectory!)
        try file(folder.appendingPathComponent("bin/Renderer64.exe"))
        XCTAssertNil(try GameGraphics.targetExecutable(game: steam, prefix: prefix))
        steam.graphicsExecutablePath = folder.appendingPathComponent("bin/Renderer64.exe").path
        XCTAssertEqual(try GameGraphics.targetExecutable(game: steam, prefix: prefix)?.lastPathComponent, "Renderer64.exe")
        steam.graphicsExecutablePath = game().executablePath
        XCTAssertThrowsError(try GameGraphics.targetExecutable(game: steam, prefix: prefix))
        let symlink = folder.appendingPathComponent("Escape.exe")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: URL(fileURLWithPath: game().executablePath))
        steam.graphicsExecutablePath = symlink.path
        XCTAssertThrowsError(try GameGraphics.targetExecutable(game: steam, prefix: prefix))
    }

    func testProfilePersistenceKeepsLegacyAutomaticAndIndependentGameValues() throws {
        let bottle = Bottle(name: "Test", status: .ready, enginePath: "/test/wine")
        var first = game(); first.bottleID = bottle.id
        first.graphicsExecutablePath = first.executablePath
        let second = Game(name: "Another game", bottleID: bottle.id, executablePath: "/offline/DX12.exe")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Store"))
        try store.save(Library(bottles: [bottle], games: [first, second]))
        let loaded = try store.load()
        XCTAssertEqual(loaded.games[0].effectiveGraphicsProfile, .directX9)
        XCTAssertEqual(loaded.games[0].graphicsExecutablePath, first.executablePath)
        XCTAssertNil(loaded.games[1].graphicsProfile)
        XCTAssertEqual(loaded.games[1].effectiveGraphicsProfile, .automatic)
    }

    func testReadinessRequiresCompletedSnapshotAndExactPerGameOverrides() throws {
        let game = game(), executable = URL(fileURLWithPath: game.executablePath)
        XCTAssertFalse(try GameGraphics.inspect(game: game, prefix: prefix).configured)
        let registry = #"[Software\\Wine\\AppDefaults\\Unknown title.exe\\DllOverrides]"# + "\n" +
            GameGraphics.overrides.sorted { $0.key < $1.key }.map { "\"\($0.key)\"=\"\($0.value)\"" }.joined(separator: "\n")
        try file(prefix.appendingPathComponent("user.reg"), registry)
        var snapshot = GameGraphics.Snapshot(gameID: game.id, executablePath: executable.path, previous: ["d3d9": "native"], complete: false)
        try GameGraphics.writeSnapshot(snapshot, prefix: prefix)
        XCTAssertFalse(try GameGraphics.inspect(game: game, prefix: prefix).configured)
        snapshot.complete = true; try GameGraphics.writeSnapshot(snapshot, prefix: prefix)
        XCTAssertTrue(try GameGraphics.inspect(game: game, prefix: prefix).configured)
        try file(prefix.appendingPathComponent("user.reg"), registry.replacingOccurrences(of: "Unknown title.exe", with: "Other.exe"))
        XCTAssertFalse(try GameGraphics.inspect(game: game, prefix: prefix).configured)
        var automatic = game; automatic.graphicsProfile = .automatic
        XCTAssertTrue(try GameGraphics.inspect(game: automatic, prefix: prefix).needsRestore)
        try FileManager.default.removeItem(at: executable)
        XCTAssertTrue(try GameGraphics.inspect(game: automatic, prefix: prefix).needsRestore)
    }

    func testSameBasenameCannotOverwriteAnotherGamesSettings() throws {
        let first = game(), executable = URL(fileURLWithPath: first.executablePath)
        try GameGraphics.writeSnapshot(.init(gameID: first.id, executablePath: executable.path, previous: [:], complete: true), prefix: prefix)
        let other = prefix.appendingPathComponent("drive_c/Other/Unknown title.exe")
        try file(other)
        XCTAssertThrowsError(try GameGraphics.checkOwnership(executable: other, gameID: UUID(), prefix: prefix))
        XCTAssertNoThrow(try GameGraphics.checkOwnership(executable: executable, gameID: first.id, prefix: prefix))
        XCTAssertNoThrow(try GameGraphics.checkOwnership(executable: other, gameID: UUID(), prefix: root.appendingPathComponent("separate")))
    }

    func testRegistryBackupKeepsStringValuesAndRejectsOtherTypes() throws {
        let values = try GameGraphics.parseQuery("HKEY_CURRENT_USER\\Software\\Wine\n    d3d9    REG_SZ    native,builtin\n    d3dx9_43    REG_SZ    builtin\n    d3d12    REG_SZ    native\n")
        XCTAssertEqual(values, ["d3d9": "native,builtin", "d3dx9_43": "builtin"])
        XCTAssertThrowsError(try GameGraphics.parseQuery("    d3d9    REG_DWORD    0x1\n"))
        XCTAssertNil(GameGraphics.overrides["dxgi"])
        XCTAssertNil(GameGraphics.overrides["d3d11"])
        XCTAssertNil(GameGraphics.overrides["d3d12"])
    }

    func testDownloadedDirectXArchiveIsVerifiedBeforeExtraction() async throws {
        let fake = root.appendingPathComponent("fake.exe")
        try file(fake)
        do {
            _ = try await DirectXLegacyRuntime.extract(fake, to: root.appendingPathComponent("extracted"))
            XCTFail("Unknown installer must not be unpacked or run")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("extracted").path)) }
    }

    /// Opt-in integration check: creates its own temporary prefix and never opens a game.
    func testRealWineAppliesAndRestoresOnlyTheSelectedExecutable() async throws {
        guard let wine = ProcessInfo.processInfo.environment["PORTICO_TEST_WINE_PATH"] else {
            throw XCTSkip("Set PORTICO_TEST_WINE_PATH for an isolated real-Wine registry check")
        }
        let engine = WineEngine()
        var bottle = Bottle(name: "Isolated graphics verification", enginePath: wine)
        let log = root.appendingPathComponent("real-wine.log")
        _ = try await engine.initialize(bottle: bottle, prefix: prefix, logURL: log, verbose: false)
        bottle.status = .ready
        var selected = game(); selected.bottleID = bottle.id
        let target = URL(fileURLWithPath: selected.executablePath)
        func reg(_ arguments: [String]) async throws -> String {
            let command = Game(name: "Registry verification", bottleID: bottle.id,
                executablePath: prefix.appendingPathComponent("drive_c/windows/system32/reg.exe").path, arguments: arguments)
            return try await engine.launch(game: command, bottle: bottle, prefix: prefix, logURL: log, verbose: false).output
        }
        _ = try await reg(["add", GameGraphics.registryKey(for: target), "/v", "d3d9", "/t", "REG_SZ", "/d", "native", "/f"])
        let otherKey = #"HKCU\Software\Wine\AppDefaults\OtherDX12.exe\DllOverrides"#
        _ = try await reg(["add", otherKey, "/v", "d3d12", "/t", "REG_SZ", "/d", "native,builtin", "/f"])
        try await engine.prepareGameGraphics(game: selected, bottle: bottle, prefix: prefix, logURL: log, verbose: false)
        let applied = try await reg(["query", GameGraphics.registryKey(for: target)])
        XCTAssertEqual(try GameGraphics.parseQuery(applied), GameGraphics.overrides)
        XCTAssertEqual(try GameGraphics.readSnapshot(gameID: selected.id, prefix: prefix)?.previous, ["d3d9": "native"])
        selected.graphicsProfile = .automatic
        try await engine.prepareGameGraphics(game: selected, bottle: bottle, prefix: prefix, logURL: log, verbose: false)
        let restored = try await reg(["query", GameGraphics.registryKey(for: target)])
        XCTAssertEqual(try GameGraphics.parseQuery(restored), ["d3d9": "native"])
        XCTAssertNil(try GameGraphics.readSnapshot(gameID: selected.id, prefix: prefix))
        let other = try await reg(["query", otherKey])
        XCTAssertTrue(other.contains("native,builtin"))
        if let redist = ProcessInfo.processInfo.environment["PORTICO_TEST_DIRECTX_ARCHIVE"] {
            let extracted = try await DirectXLegacyRuntime.extract(URL(fileURLWithPath: redist), to: root.appendingPathComponent("DirectX"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))
            for architecture in ["x86", "x64"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.deletingLastPathComponent()
                    .appendingPathComponent("Jun2010_d3dx9_43_\(architecture).cab").path))
            }
        }
    }
}
