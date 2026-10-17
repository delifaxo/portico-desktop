import XCTest
@testable import PorticoCore

final class WineEngineTests: XCTestCase {
    private var root: URL!
    private var wine: URL!
    private var server: URL!
    private var prefix: URL!
    private var log: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Portico Wine Tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        wine = root.appendingPathComponent("engine/wine")
        server = root.appendingPathComponent("engine/wineserver")
        prefix = root.appendingPathComponent("prefix with spaces")
        log = root.appendingPathComponent("logs/session.log")
        try script(wine, #"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            printf 'wine-11.0 (test runtime)\n'
            printf 'version stderr\n' >&2
            exit 0
        fi
        printf '%s\n' "$@" > "$WINEPREFIX/arguments.txt"
        case "$*" in *steam.exe*)
            steam_test_client="$1"
            if [ "$1" = "explorer.exe" ]; then steam_test_client="$3"; fi
            steam_test_logs="${steam_test_client%/*}/logs"
            /bin/mkdir -p "$steam_test_logs"
            printf 'BrowserReady: test\n' >> "$steam_test_logs/steamui_html.txt"
        ;; esac
        printf '%s\n' "$WINEPREFIX" "$WINEDEBUG" "$WINESERVER" "$PATH" > "$WINEPREFIX/environment.txt"
        printf '%s\n' "$MTL_HUD_ENABLED" > "$WINEPREFIX/hud.txt"
        printf '%s\n' "$D3DM_ENABLE_METALFX" > "$WINEPREFIX/metalfx.txt"
        /bin/pwd > "$WINEPREFIX/cwd.txt"
        if [ "$1" = "wineboot.exe" ]; then
            /bin/mkdir -p "$WINEPREFIX/drive_c"
            /usr/bin/touch "$WINEPREFIX/system.reg"
        fi
        printf 'stdout from fake wine\n'
        printf 'stderr from fake wine\n' >&2
        if [ -f "$WINEPREFIX/fail" ]; then exit 37; fi
        exit 0
        """#)
        try script(server, #"""
        #!/bin/sh
        printf '%s\n' "$1" >> "$WINEPREFIX/server-calls.txt"
        if [ "$1" = "-k" ]; then /bin/rm -f "$WINEPREFIX/hold"; fi
        if [ "$1" = "-w" ]; then
            /usr/bin/touch "$WINEPREFIX/server-waiting"
            while [ -f "$WINEPREFIX/hold" ]; do /bin/sleep 0.02; done
        fi
        exit 0
        """#)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testProbeCapturesBothStreams() async throws {
        let result = try await WineEngine().probe(executable: wine)
        XCTAssertTrue(result.contains("wine-11.0 (test runtime)"))
        XCTAssertTrue(result.contains("version stderr"))
    }

    func testInitializeWaitsForServerAndCreatesUsablePrefix() async throws {
        let engine = WineEngine()
        let result = try await engine.initialize(bottle: bottle(status: .creating), prefix: prefix, logURL: log, verbose: false)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try read("arguments.txt"), "wineboot.exe\n-u\n")
        XCTAssertEqual(try read("server-calls.txt"), "-w\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path))
        let running = await engine.isRunning(prefix: prefix)
        XCTAssertFalse(running)
    }

    func testLaunchKeepsArgumentsLiteralAndIsolatesEnvironment() async throws {
        try makeReady()
        let sentinel = root.appendingPathComponent("should-not-exist")
        let executable = root.appendingPathComponent("game folder/Divinity ; $(touch nope).EXE")
        try file(executable)
        let bottle = bottle()
        let arguments = ["", " two words ", "; touch \(sentinel.path)", "$(touch \(sentinel.path))", "quote\"'`", "--option=value"]
        let game = Game(name: "Test", bottleID: bottle.id, executablePath: executable.path, arguments: arguments)
        let originalPrefix = ProcessInfo.processInfo.environment["WINEPREFIX"]
        let result = try await WineEngine().launch(game: game, bottle: bottle, prefix: prefix, logURL: log, verbose: false)
        XCTAssertEqual(try read("arguments.txt"), ([executable.path] + arguments).joined(separator: "\n") + "\n")
        let environment = try read("environment.txt").components(separatedBy: "\n")
        XCTAssertEqual(environment[0], prefix.resolvingSymlinksInPath().path)
        XCTAssertEqual(environment[1], "-all")
        XCTAssertEqual(environment[2], server.resolvingSymlinksInPath().path)
        XCTAssertTrue(environment[3].hasPrefix(wine.deletingLastPathComponent().path + ":"))
        let actualDirectory = URL(fileURLWithPath: try read("cwd.txt").trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(actualDirectory.resolvingSymlinksInPath().path, executable.deletingLastPathComponent().resolvingSymlinksInPath().path)
        XCTAssertEqual(ProcessInfo.processInfo.environment["WINEPREFIX"], originalPrefix)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(result.output.contains("stdout from fake wine"))
        XCTAssertTrue(result.output.contains("stderr from fake wine"))
    }

    func testFPSSettingReachesGameProcessOnAndOff() async throws {
        try makeReady()
        let executable = root.appendingPathComponent("Game.exe")
        try file(executable)
        let selected = bottle()
        let game = Game(name: "Game", bottleID: selected.id, executablePath: executable.path)
        let engine = WineEngine()
        _ = try await engine.launch(game: game, bottle: selected, prefix: prefix, logURL: log, verbose: false, showFPS: true)
        XCTAssertEqual(try read("hud.txt"), "1\n")
        _ = try await engine.launch(game: game, bottle: selected, prefix: prefix, logURL: log, verbose: false, showFPS: false)
        XCTAssertEqual(try read("hud.txt"), "0\n")
    }

    func testMetalFXSettingReachesDirectAndSteamLaunchesAndCanBeDisabled() async throws {
        try makeReady()
        let (engine, selected) = try metalFXRuntime()
        let executable = root.appendingPathComponent("Game.exe")
        try file(executable)
        var game = Game(name: "Game", bottleID: selected.id, executablePath: executable.path)
        game.enableMetalFX = true
        _ = try await engine.launch(game: game, bottle: selected, prefix: prefix, logURL: log, verbose: false)
        XCTAssertEqual(try read("metalfx.txt"), "1\n")
        game.enableMetalFX = false
        _ = try await engine.launch(game: game, bottle: selected, prefix: prefix, logURL: log, verbose: false)
        XCTAssertEqual(try read("metalfx.txt"), "0\n")
        try file(prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
        game.steamAppID = "1297900"
        game.enableMetalFX = true
        _ = try await engine.launch(game: game, bottle: selected, prefix: prefix, logURL: log, verbose: false)
        XCTAssertEqual(try read("metalfx.txt"), "1\n")
        XCTAssertTrue(try read("arguments.txt").contains("steam://rungameid/1297900"))
    }

    func testChangingMetalFXRequiresSteamRestartAndPreservesRunningSession() async throws {
        try makeReady()
        let (engine, selected) = try metalFXRuntime()
        try file(prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
        try file(prefix.appendingPathComponent("hold"))
        let selectedPrefix = prefix!, selectedLog = log!
        let session = Task {
            try await engine.steam(action: .library, bottle: selected, prefix: selectedPrefix,
                logURL: selectedLog, verbose: false, enableMetalFX: true)
        }
        defer { session.cancel() }
        try await waitForFile(prefix.appendingPathComponent("server-waiting"))
        XCTAssertEqual(try read("metalfx.txt"), "1\n")
        _ = try await engine.steam(action: .downloads, bottle: selected, prefix: prefix,
            logURL: log, verbose: false, existingSessionOnly: true)
        XCTAssertEqual(try read("metalfx.txt"), "1\n")
        do {
            _ = try await engine.steam(action: .run(appID: "1297900"), bottle: selected, prefix: prefix,
                logURL: log, verbose: false, existingSessionOnly: true, enableMetalFX: false)
            XCTFail("Steam children inherit the client's original MetalFX setting")
        } catch PorticoError.invalidInput(let message) {
            XCTAssertTrue(message.contains("MetalFX"))
        }
        let running = await engine.isRunning(prefix: prefix)
        XCTAssertTrue(running)
        XCTAssertFalse(try read("server-calls.txt").contains("-k"))
        try await engine.stop(bottle: selected, prefix: prefix)
        _ = try await session.value
    }

    func testUnmanagedSteamCannotSilentlyIgnoreMetalFXSetting() async throws {
        try makeReady()
        let (engine, selected) = try metalFXRuntime()
        try file(prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
        try file(prefix.appendingPathComponent("hold"))
        try Data("0\n".utf8).write(to: prefix.appendingPathComponent("metalfx.txt"))
        do {
            _ = try await engine.steam(action: .run(appID: "1297900"), bottle: selected,
                prefix: prefix, logURL: log, verbose: false, enableMetalFX: true)
            XCTFail("An external client must be closed before configuring its children")
        } catch PorticoError.invalidInput(let message) {
            XCTAssertTrue(message.contains("MetalFX"))
        }
        XCTAssertEqual(try read("metalfx.txt"), "0\n")
        XCTAssertFalse(try read("server-calls.txt").contains("-k"))
        try FileManager.default.removeItem(at: prefix.appendingPathComponent("hold"))
    }

    private func metalFXRuntime() throws -> (WineEngine, Bottle) {
        let graphics = root.resolvingSymlinksInPath().appendingPathComponent("graphics", isDirectory: true)
        let runtime = graphics.appendingPathComponent("runtime", isDirectory: true)
        for (path, executable) in LocalGraphicsRuntime.requiredFiles {
            let target = runtime.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if path == "bin/wine64" { try FileManager.default.copyItem(at: wine, to: target) }
            else if path == "bin/wineserver" {
                let contents = try String(contentsOf: server, encoding: .utf8)
                try script(target, contents.replacingOccurrences(of: "if [ \"$1\" = \"-w\" ]; then",
                    with: "if [ \"$1\" = \"-w\" ] && [ -f \"$WINEPREFIX/metalfx.txt\" ]; then"))
            }
            else {
                try Data("fixture".utf8).write(to: target)
                if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
            }
        }
        let registration = try LocalGraphicsRuntime.snapshot(runtime: runtime, version: "test")
        try FileManager.default.createDirectory(at: graphics.appendingPathComponent("LocalRuntimes", isDirectory: true), withIntermediateDirectories: true)
        try LocalGraphicsRuntime.save(registration, rootURL: graphics)
        let selected = Bottle(name: "MetalFX fixture", status: .ready,
            enginePath: try GraphicsRuntimeLocation.reference(providerID: registration.providerID),
            graphics: BottleGraphics(backend: .d3dMetal, providerID: registration.providerID))
        return (WineEngine(graphicsRoot: graphics), selected)
    }

    func testLaunchUsesExplicitWorkingDirectory() async throws {
        try makeReady()
        let executable = root.appendingPathComponent("Jagged Alliance 2/bin/JA2.exe")
        try file(executable)
        let workingDirectory = root.appendingPathComponent("Jagged Alliance 2")
        let selectedBottle = bottle()
        let game = Game(name: "Jagged Alliance 2", bottleID: selectedBottle.id,
                        executablePath: executable.path, workingDirectory: workingDirectory.path)

        _ = try await WineEngine().launch(game: game, bottle: selectedBottle, prefix: prefix, logURL: log, verbose: false)

        let actualDirectory = URL(fileURLWithPath: try read("cwd.txt").trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(actualDirectory.resolvingSymlinksInPath(), workingDirectory.resolvingSymlinksInPath())
        XCTAssertEqual(try read("arguments.txt"), executable.path + "\n")
    }

    func testExplicitDirectRouteOverridesRetainedSteamMetadata() async throws {
        try makeReady()
        let executable = root.appendingPathComponent("Game.exe")
        try file(executable)
        let selected = bottle()
        let game = Game(name: "Game", bottleID: selected.id, executablePath: executable.path,
                        arguments: ["--windowed"], steamAppID: "1771300", launchMethod: .executable)
        _ = try await WineEngine().launch(game: game, bottle: selected, prefix: prefix, logURL: log, verbose: false)
        XCTAssertEqual(try read("arguments.txt"), executable.path + "\n--windowed\n")
    }

    func testInvalidLaunchConfigurationIsRejectedBeforeStartingWine() async throws {
        try makeReady()
        let executable = root.appendingPathComponent("valid game.exe")
        try file(executable)
        let textFile = root.appendingPathComponent("not a game.txt")
        try file(textFile)
        let directoryWithExeExtension = root.appendingPathComponent("folder.exe")
        try FileManager.default.createDirectory(at: directoryWithExeExtension, withIntermediateDirectories: true)
        let selectedBottle = bottle()
        let valid = Game(name: "Test", bottleID: selectedBottle.id, executablePath: executable.path)
        var invalidGames: [(String, Game)] = []
        for path in ["", "relative.exe", textFile.path, root.appendingPathComponent("missing.exe").path,
                     directoryWithExeExtension.path, executable.path + "\u{0000}.exe"] {
            var game = valid
            game.executablePath = path
            invalidGames.append(("executable \(String(reflecting: path))", game))
        }
        for path in ["", "relative folder", root.appendingPathComponent("missing folder").path,
                     executable.path, root.path + "\u{0000}"] {
            var game = valid
            game.workingDirectory = path
            invalidGames.append(("working directory \(String(reflecting: path))", game))
        }
        var nulArgument = valid
        nulArgument.arguments = ["before\u{0000}after"]
        invalidGames.append(("NUL argument", nulArgument))
        let engine = WineEngine()

        for (description, game) in invalidGames {
            do {
                _ = try await engine.launch(game: game, bottle: selectedBottle, prefix: prefix, logURL: log, verbose: false)
                XCTFail("Expected invalid input: \(description)")
            } catch PorticoError.invalidInput { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("arguments.txt").path), description)
            XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("server-calls.txt").path), description)
            XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), description)
        }
    }

    func testTwoGameProfilesKeepArgumentsDirectoriesAndPrefixesIndependent() async throws {
        try makeReady()
        let firstExecutable = root.appendingPathComponent("Divinity/bin/EoCApp.exe")
        let secondExecutable = root.appendingPathComponent("Jagged Alliance 2/bin/JA2.exe")
        try file(firstExecutable)
        try file(secondExecutable)
        let firstBottle = bottle()
        let secondBottle = bottle()
        let secondPrefix = root.appendingPathComponent("JA2 prefix")
        try makeReady(at: secondPrefix)
        let secondDirectory = root.appendingPathComponent("Jagged Alliance 2")
        let first = Game(name: "Divinity", bottleID: firstBottle.id, executablePath: firstExecutable.path,
                         arguments: ["--skip-launcher", "first profile"])
        let second = Game(name: "Jagged Alliance 2", bottleID: secondBottle.id, executablePath: secondExecutable.path,
                          arguments: ["second profile", ""], workingDirectory: secondDirectory.path)
        let engine = WineEngine()

        _ = try await engine.launch(game: first, bottle: firstBottle, prefix: prefix, logURL: log, verbose: false)
        _ = try await engine.launch(game: second, bottle: secondBottle, prefix: secondPrefix,
                                    logURL: root.appendingPathComponent("logs/second.log"), verbose: true)

        for (game, selectedPrefix, expectedDirectory, debug) in [
            (first, prefix!, firstExecutable.deletingLastPathComponent(), "-all"),
            (second, secondPrefix, secondDirectory, "+timestamp,+pid,+tid,+seh,+loaddll")
        ] {
            let arguments = try String(contentsOf: selectedPrefix.appendingPathComponent("arguments.txt"), encoding: .utf8)
            XCTAssertEqual(arguments, ([game.executablePath] + game.arguments).joined(separator: "\n") + "\n")
            let directory = try String(contentsOf: selectedPrefix.appendingPathComponent("cwd.txt"), encoding: .utf8)
            XCTAssertEqual(URL(fileURLWithPath: directory.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath(),
                           expectedDirectory.resolvingSymlinksInPath())
            let environment = try String(contentsOf: selectedPrefix.appendingPathComponent("environment.txt"), encoding: .utf8)
                .components(separatedBy: "\n")
            XCTAssertEqual(environment[0], selectedPrefix.resolvingSymlinksInPath().path)
            XCTAssertEqual(environment[1], debug)
        }
    }

    func testMSIUsesMsiexecAndNonzeroExitIsReported() async throws {
        try makeReady()
        let installer = root.appendingPathComponent("installer with spaces.msi")
        try file(installer)
        let engine = WineEngine()
        _ = try await engine.install(installer: installer, bottle: bottle(), prefix: prefix, logURL: log, verbose: true)
        XCTAssertEqual(try read("arguments.txt"), "msiexec.exe\n/i\n\(installer.path)\n")
        XCTAssertTrue(try read("environment.txt").contains("+seh"))
        try file(prefix.appendingPathComponent("fail"))
        do {
            _ = try await engine.configure(bottle: bottle(), prefix: prefix, logURL: log, verbose: false)
            XCTFail("Expected a process failure")
        } catch PorticoError.processFailed(let code, let output) {
            XCTAssertEqual(code, 37)
            XCTAssertTrue(output.contains("stderr from fake wine"))
        }
        let running = await engine.isRunning(prefix: prefix)
        XCTAssertFalse(running)
    }

    func testRejectsNonreadyMissingInvalidAndWrongBottleInputs() async throws {
        let engine = WineEngine()
        do {
            _ = try await engine.configure(bottle: bottle(), prefix: prefix, logURL: log, verbose: false)
            XCTFail("Missing prefix must fail")
        } catch PorticoError.invalidInput { }
        try makeReady()
        do {
            _ = try await engine.configure(bottle: bottle(status: .creating), prefix: prefix, logURL: log, verbose: false)
            XCTFail("Nonready prefix must fail")
        } catch PorticoError.invalidInput { }
        let installer = root.appendingPathComponent("wrong.txt")
        try file(installer)
        do {
            _ = try await engine.install(installer: installer, bottle: bottle(), prefix: prefix, logURL: log, verbose: false)
            XCTFail("Invalid extension must fail")
        } catch PorticoError.invalidInput { }
        let executable = root.appendingPathComponent("game.exe")
        try file(executable)
        do {
            _ = try await engine.launch(game: Game(name: "wrong", bottleID: UUID(), executablePath: executable.path), bottle: bottle(), prefix: prefix, logURL: log, verbose: false)
            XCTFail("Mismatched bottle must fail")
        } catch PorticoError.invalidInput { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("arguments.txt").path))
    }

    func testMissingMatchingServerIsRejectedBeforeLaunchingOrStopping() async throws {
        try makeReady()
        try FileManager.default.removeItem(at: server)
        let engine = WineEngine()
        do {
            _ = try await engine.configure(bottle: bottle(), prefix: prefix, logURL: log, verbose: false)
            XCTFail("Missing server must fail")
        } catch PorticoError.runtimeUnavailable { }
        do {
            try await engine.stop(bottle: bottle(), prefix: prefix)
            XCTFail("Stop may not fall back to a global server")
        } catch PorticoError.runtimeUnavailable { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("arguments.txt").path))
    }

    func testBusyLockCoversDetachedServerAndStopOnlyTouchesSelectedPrefix() async throws {
        try makeReady()
        let engine = WineEngine()
        let bottle = bottle()
        let firstPrefix = prefix!
        let firstLog = log!
        try file(firstPrefix.appendingPathComponent("hold"))
        let operation = Task { try await engine.configure(bottle: bottle, prefix: firstPrefix, logURL: firstLog, verbose: false) }
        try await waitForFile(firstPrefix.appendingPathComponent("server-waiting"))
        let running = await engine.isRunning(prefix: firstPrefix)
        XCTAssertTrue(running)
        do {
            _ = try await engine.configure(bottle: bottle, prefix: firstPrefix, logURL: log, verbose: false)
            XCTFail("Concurrent operations on the same prefix must fail")
        } catch PorticoError.busy { }
        let second = root.appendingPathComponent("second prefix")
        try makeReady(at: second)
        _ = try await engine.configure(bottle: self.bottle(), prefix: second, logURL: root.appendingPathComponent("second.log"), verbose: false)
        try file(second.appendingPathComponent("hold"))
        try await engine.stop(bottle: bottle, prefix: firstPrefix)
        _ = try await operation.value
        let stillRunning = await engine.isRunning(prefix: firstPrefix)
        XCTAssertFalse(stillRunning)
        XCTAssertTrue(try read("server-calls.txt").contains("-w\n-k\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("hold").path))
    }

    func testCancellationStopsPrefixBeforeReleasingLock() async throws {
        try makeReady()
        let engine = WineEngine()
        let selectedBottle = bottle()
        let selectedPrefix = prefix!
        let selectedLog = log!
        try file(selectedPrefix.appendingPathComponent("hold"))
        let operation = Task { try await engine.configure(bottle: selectedBottle, prefix: selectedPrefix, logURL: selectedLog, verbose: false) }
        try await waitForFile(selectedPrefix.appendingPathComponent("server-waiting"))
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Cancelled operation must throw")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: selectedPrefix.appendingPathComponent("hold").path))
        XCTAssertTrue(try read("server-calls.txt").contains("-k\n-w\n"))
        let running = await engine.isRunning(prefix: selectedPrefix)
        XCTAssertFalse(running)
    }

    func testSteamGameLaunchUsesWindowsClientAndValidatedProtocol() async throws {
        try makeReady()
        let client = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        try file(client)
        let selectedBottle = bottle()
        let game = Game(name: "Steam game", bottleID: selectedBottle.id,
                        executablePath: "/unused/game.exe", steamAppID: "435150")
        _ = try await WineEngine().launch(game: game, bottle: selectedBottle, prefix: prefix, logURL: log, verbose: false)
        XCTAssertEqual(try read("arguments.txt"), "\(client.path)\nsteam://rungameid/435150\n")
        XCTAssertEqual(try read("server-calls.txt"), "-w\n")
    }

    func testSteamUninstallUsesOnlyTheSelectedWindowsClient() async throws {
        try makeReady()
        let client = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        try file(client)
        let otherPrefix = root.appendingPathComponent("other prefix")
        let otherGame = otherPrefix.appendingPathComponent("drive_c/Game/game.exe")
        try file(otherGame)
        _ = try await WineEngine().steam(action: .uninstall(appID: "000435150"), bottle: bottle(),
                                        prefix: prefix, logURL: log, verbose: false)
        XCTAssertEqual(try read("arguments.txt"), "\(client.path)\nsteam://uninstall/435150\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherGame.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherPrefix.appendingPathComponent("arguments.txt").path))
    }

    func testSteamFPSPreferenceRequiresRestartWithoutStoppingExistingSession() async throws {
        try makeReady()
        try file(prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
        try file(prefix.appendingPathComponent("hold"))
        let engine = WineEngine(), selected = bottle()
        let selectedPrefix = prefix!, selectedLog = log!
        let session = Task {
            try await engine.steam(action: .library, bottle: selected, prefix: selectedPrefix,
                logURL: selectedLog, verbose: false, showFPS: true)
        }
        defer { session.cancel() }
        try await waitForFile(prefix.appendingPathComponent("server-waiting"))
        XCTAssertEqual(try read("hud.txt"), "1\n")
        do {
            _ = try await engine.steam(action: .run(appID: "435150"), bottle: selected,
                prefix: prefix, logURL: log, verbose: false, existingSessionOnly: true, showFPS: false)
            XCTFail("A running Steam client cannot inherit a changed HUD preference")
        } catch PorticoError.invalidInput(let message) {
            XCTAssertTrue(message.contains("FPS"))
        }
        XCTAssertEqual(try read("server-calls.txt"), "-w\n")
        let stillRunning = await engine.isRunning(prefix: prefix)
        XCTAssertTrue(stillRunning)
        try await engine.stop(bottle: selected, prefix: prefix)
        _ = try await session.value
    }

    func testSteamUpdateRestartDoesNotKillTheNewClient() async throws {
        try makeReady()
        try file(prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
        try script(wine, #"""
        #!/bin/sh
        /usr/bin/touch "$WINEPREFIX/hold"
        printf 'Update complete, launching Steam...\n'
        exit 42
        """#)
        let engine = WineEngine(), savedBottle = bottle()
        let selectedPrefix = prefix!, selectedLog = log!
        let session = Task {
            try await engine.steam(action: .library, bottle: savedBottle, prefix: selectedPrefix, logURL: selectedLog, verbose: false)
        }
        defer { session.cancel() }
        try await waitForFile(prefix.appendingPathComponent("server-waiting"))
        XCTAssertEqual(try read("server-calls.txt"), "-w\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("hold").path))
        try await engine.stop(bottle: savedBottle, prefix: prefix)
        let result = try await session.value
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSteamNavigationCannotRaceStartupOrUseAnOldReadyMarker() async throws {
        try makeReady()
        let client = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        try file(client)
        let htmlLog = client.deletingLastPathComponent().appendingPathComponent("logs/steamui_html.txt")
        try FileManager.default.createDirectory(at: htmlLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("BrowserReady: previous session\n".utf8).write(to: htmlLog)
        try script(wine, #"""
        #!/bin/sh
        /usr/bin/touch "$WINEPREFIX/hold"
        exit 0
        """#)
        let engine = WineEngine(), savedBottle = bottle()
        let selectedPrefix = prefix!, selectedLog = log!
        let session = Task {
            try await engine.steam(action: .library, bottle: savedBottle, prefix: selectedPrefix, logURL: selectedLog, verbose: false)
        }
        defer { session.cancel() }
        try await waitForFile(prefix.appendingPathComponent("server-waiting"))
        let initiallyReady = await engine.isSteamReady(prefix: prefix)
        XCTAssertFalse(initiallyReady)
        do {
            _ = try await engine.steam(action: .downloads, bottle: savedBottle, prefix: prefix, logURL: log, verbose: false)
            XCTFail("A second process must not become the client during startup")
        } catch PorticoError.busy { }
        let handle = try FileHandle(forWritingTo: htmlLog)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("BrowserReady: current session\n".utf8))
        try handle.close()
        let ready = await engine.isSteamReady(prefix: prefix)
        XCTAssertTrue(ready)
        try await engine.stop(bottle: savedBottle, prefix: prefix)
        _ = try await session.value
    }

    func testSteamCommandsReachRunningSessionWithoutUnlockingOrReplacingLog() async throws {
        try makeReady()
        try file(prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
        try file(prefix.appendingPathComponent("hold"))
        let engine = WineEngine()
        let selectedBottle = bottle()
        let selectedPrefix = prefix!
        let selectedLog = log!
        let session = Task {
            try await engine.steam(action: .library, bottle: selectedBottle, prefix: selectedPrefix, logURL: selectedLog, verbose: false)
        }
        defer { session.cancel() }
        try await waitForFile(prefix.appendingPathComponent("server-waiting"))
        _ = try await engine.steam(action: .downloads, bottle: selectedBottle, prefix: prefix, logURL: log, verbose: false, existingSessionOnly: true)
        XCTAssertTrue(try read("arguments.txt").contains("steam://open/downloads"))
        XCTAssertEqual(try read("server-calls.txt"), "-w\n", "A URI command must not wait for or stop the client")
        let running = await engine.isRunning(prefix: prefix)
        XCTAssertTrue(running)
        let logContents = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logContents.contains("steam://open/games"))
        XCTAssertTrue(logContents.contains("steam://open/downloads"))
        do {
            _ = try await engine.configure(bottle: selectedBottle, prefix: prefix, logURL: log, verbose: false)
            XCTFail("A running Steam session still owns its prefix")
        } catch PorticoError.busy { }
        try await engine.stop(bottle: selectedBottle, prefix: prefix)
        _ = try await session.value
        let ended = await engine.isRunning(prefix: prefix)
        XCTAssertFalse(ended)
    }

    func testSteamDesktopStartsOnceAndNavigationPreservesSession() async throws {
        try makeReady()
        let client = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        try file(client)
        let launcher = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/Steam/steamwebhelper.exe")
        let helper = client.deletingLastPathComponent().appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        var helperData = try Data(contentsOf: launcher)
        helperData.append(Data(repeating: 0, count: 500_000))
        try helperData.write(to: helper)
        let fakeWine = try String(contentsOf: wine)
        try fakeWine.replacingOccurrences(of: "printf '%s\\n' \"$@\"", with: "if [ \"$1\" = \"explorer.exe\" ]; then /usr/bin/touch \"$WINEPREFIX/hold\"; fi\nprintf '%s\\n' \"$@\"")
            .write(to: wine, atomically: false, encoding: .utf8)
        var selectedBottle = bottle()
        selectedBottle.steamDesktop = true
        let savedBottle = selectedBottle
        let engine = WineEngine(initializationTimeout: 120, steamLauncher: launcher)
        let selectedPrefix = prefix!, selectedLog = log!
        let session = Task {
            try await engine.steam(action: .library, bottle: savedBottle, prefix: selectedPrefix, logURL: selectedLog, verbose: false)
        }
        defer { session.cancel() }
        try await waitForFile(prefix.appendingPathComponent("arguments.txt"))
        XCTAssertEqual(try read("arguments.txt"), "explorer.exe\n/desktop=PorticoSteam,1280x800\n\(client.path)\n-noverifyfiles\n-cef-disable-gpu\nsteam://open/games\n")
        let readyDeadline = Date().addingTimeInterval(2)
        while !(await engine.isSteamReady(prefix: prefix)) && Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await engine.steam(action: .run(appID: "1771300"), bottle: savedBottle, prefix: prefix, logURL: log, verbose: false, existingSessionOnly: true)
        XCTAssertEqual(try read("arguments.txt"), "\(client.path)\n-noverifyfiles\n-cef-disable-gpu\nsteam://rungameid/1771300\n")
        XCTAssertEqual(try read("server-calls.txt"), "-w\n-w\n")
        try await engine.stop(bottle: savedBottle, prefix: prefix)
        _ = try await session.value
    }

    func testFailedSteamCommandLeavesExistingSessionAndDownloadsAlive() async throws {
        try makeReady()
        try file(prefix.appendingPathComponent("drive_c/Program Files/Steam/steam.exe"))
        try file(prefix.appendingPathComponent("hold"))
        let engine = WineEngine()
        let selectedBottle = bottle()
        let selectedPrefix = prefix!
        let selectedLog = log!
        let session = Task {
            try await engine.steam(action: .library, bottle: selectedBottle, prefix: selectedPrefix, logURL: selectedLog, verbose: false)
        }
        defer { session.cancel() }
        try await waitForFile(prefix.appendingPathComponent("server-waiting"))
        try file(prefix.appendingPathComponent("fail"))
        do {
            _ = try await engine.steam(action: .store, bottle: selectedBottle, prefix: prefix, logURL: log, verbose: false)
            XCTFail("Expected command failure")
        } catch PorticoError.processFailed(let code, _) { XCTAssertEqual(code, 37) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("hold").path))
        XCTAssertEqual(try read("server-calls.txt"), "-w\n")
        try await engine.stop(bottle: selectedBottle, prefix: prefix)
        _ = try await session.value
    }

    func testSteamCannotBypassInstallerLockOrStartUntrackedSession() async throws {
        try makeReady()
        try file(prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"))
        let engine = WineEngine()
        let selectedBottle = bottle()
        do {
            _ = try await engine.steam(action: .library, bottle: selectedBottle, prefix: prefix, logURL: log, verbose: false, existingSessionOnly: true)
            XCTFail("A secondary command must never create an untracked session")
        } catch PorticoError.invalidInput { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("arguments.txt").path))
        try file(prefix.appendingPathComponent("hold"))
        let selectedPrefix = prefix!
        let selectedLog = log!
        let operation = Task {
            try await engine.configure(bottle: selectedBottle, prefix: selectedPrefix, logURL: selectedLog, verbose: false)
        }
        defer { operation.cancel() }
        try await waitForFile(prefix.appendingPathComponent("server-waiting"))
        do {
            _ = try await engine.steam(action: .library, bottle: selectedBottle, prefix: prefix, logURL: log, verbose: false)
            XCTFail("Steam cannot enter a non-Steam operation")
        } catch PorticoError.busy { }
        try await engine.stop(bottle: selectedBottle, prefix: prefix)
        _ = try await operation.value
    }

    func testSteamRejectsInvalidIDsAndMissingClientBeforeStartingWine() async throws {
        try makeReady()
        let engine = WineEngine()
        for appID in ["", "0", "-1", "１２", "12/../3", "1; touch sentinel", "4294967296"] {
            XCTAssertThrowsError(try SteamAction.install(appID: appID).uri)
            do {
                _ = try await engine.steam(action: .run(appID: appID), bottle: bottle(), prefix: prefix, logURL: log, verbose: false)
                XCTFail("Invalid ID should fail")
            } catch PorticoError.invalidInput { }
        }
        do {
            _ = try await engine.steam(action: .library, bottle: bottle(), prefix: prefix, logURL: log, verbose: false)
            XCTFail("Missing Windows client should fail")
        } catch PorticoError.invalidInput { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.appendingPathComponent("arguments.txt").path))
        XCTAssertEqual(try SteamAction.install(appID: "000435150").uri, "steam://install/435150")
    }

    func testCrossOverWrapperRequiresSeparateAdapter() async throws {
        let wrapper = root.appendingPathComponent("CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        try script(wrapper, "#!/bin/sh\necho should-not-run\n")
        do {
            _ = try await WineEngine().probe(executable: wrapper)
            XCTFail("CrossOver's bottle routing must not be used as standalone Wine")
        } catch PorticoError.runtimeUnavailable(let message) {
            XCTAssertTrue(message.contains("CrossOver"))
        }
    }

    func testLargeOutputDrainsBothPipesAndBoundsLogAndTail() async throws {
        try makeReady()
        try script(wine, #"""
        #!/bin/sh
        /usr/bin/head -c 3145728 /dev/zero | /usr/bin/tr '\000' 'x'
        /usr/bin/head -c 3145728 /dev/zero | /usr/bin/tr '\000' 'y' >&2
        printf '\nfinished-output\n' >&2
        """#)
        let result = try await WineEngine().configure(bottle: bottle(), prefix: prefix, logURL: log, verbose: false)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("finished-output"))
        XCTAssertLessThanOrEqual(result.output.utf8.count, 32 * 1024)
        let size = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as! NSNumber
        XCTAssertLessThanOrEqual(size.intValue, 2 * 1024 * 1024)
    }

    func testProbeRejectsMissingServerAndNonWineVersion() async throws {
        try script(wine, "#!/bin/sh\necho arbitrary-program-1.0\n")
        do {
            _ = try await WineEngine().probe(executable: wine)
            XCTFail("Unrelated executables must not validate as Wine")
        } catch PorticoError.runtimeUnavailable { }
        try FileManager.default.removeItem(at: server)
        do {
            _ = try await WineEngine().probe(executable: wine)
            XCTFail("An incomplete runtime must not validate")
        } catch PorticoError.runtimeUnavailable { }
    }

    func testDetachedChildOutputRemainsOpenUntilServerExits() async throws {
        try makeReady()
        try script(wine, #"""
        #!/bin/sh
        /usr/bin/touch "$WINEPREFIX/hold"
        ( /bin/sleep 0.15; printf 'late-child-output\n'; /bin/rm -f "$WINEPREFIX/hold" ) &
        exit 0
        """#)
        let result = try await WineEngine().configure(bottle: bottle(), prefix: prefix, logURL: log, verbose: false)
        XCTAssertTrue(result.output.contains("late-child-output"))
        XCTAssertTrue(result.output.contains(L10n.text("[Portico] Операцію завершено.\n")))
    }

    func testProbeTimeoutTerminatesUnresponsiveRuntime() async throws {
        try script(wine, "#!/bin/sh\ntrap '' TERM\nwhile :; do /bin/sleep 1; done\n")
        let start = Date()
        do {
            _ = try await WineEngine().probe(executable: wine)
            XCTFail("Probe must time out")
        } catch PorticoError.runtimeUnavailable(let message) {
            XCTAssertEqual(message, L10n.text("Wine не відповів вчасно; процес операції зупинено. Перевірте системні вікна macOS і журнал."))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 12)
    }

    func testGraphicsPreparationRefusesAnyRunningGameAndKeepsSteamAlive() async throws {
        guard !DistributionPolicy.isAppStore else { throw XCTSkip("External prerequisites disabled") }
        try makeReady()
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        try file(steam)
        try file(prefix.appendingPathComponent("hold"))
        try script(wine, #"""
        #!/bin/sh
        if [ "$1" = "tasklist" ]; then
            printf '"ArbitraryGame.exe","240","Console","1","100 K"\n'
            exit 0
        fi
        client_dir="${1%/*}"
        /bin/mkdir -p "$client_dir/logs"
        printf 'BrowserReady: fixture\n' >> "$client_dir/logs/steamui_html.txt"
        exit 0
        """#)
        let engine = WineEngine(), selected = bottle()
        let executable = prefix.appendingPathComponent("drive_c/ArbitraryGame.exe")
        try file(executable)
        var game = Game(name: "An arbitrary game", bottleID: selected.id, executablePath: executable.path)
        game.graphicsProfile = .directX9
        let steamTask = Task { try await engine.steam(action: .library, bottle: selected, prefix: prefix, logURL: log, verbose: false) }
        try await waitForFile(prefix.appendingPathComponent("server-waiting"))
        do {
            try await engine.prepareGameGraphics(game: game, bottle: selected, prefix: prefix, logURL: log, verbose: false)
            XCTFail("An active game must block prerequisite changes")
        } catch PorticoError.invalidInput(let message) {
            XCTAssertEqual(message, L10n.text("Закрийте гру перед налаштуванням графіки. Steam можна залишити відкритим."))
        }
        let stillRunning = await engine.isRunning(prefix: prefix)
        XCTAssertTrue(stillRunning)
        XCTAssertFalse(try read("server-calls.txt").contains("-k"))
        try FileManager.default.removeItem(at: prefix.appendingPathComponent("hold"))
        _ = try await steamTask.value
    }

    private func bottle(status: BottleStatus = .ready) -> Bottle {
        Bottle(name: "Test bottle", status: status, enginePath: wine.path)
    }
    private func script(_ url: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    private func file(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
    private func makeReady(at url: URL? = nil) throws {
        let target = url ?? prefix!
        try FileManager.default.createDirectory(at: target.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try file(target.appendingPathComponent("system.reg"))
    }
    private func read(_ name: String) throws -> String {
        try String(contentsOf: prefix.appendingPathComponent(name), encoding: .utf8)
    }
    private func waitForFile(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: url.path) {
            if Date() >= deadline { throw PorticoError.storage("Test process did not reach server wait") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
