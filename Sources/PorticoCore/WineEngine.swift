import Foundation
import Darwin

/// Runs an explicitly installed Wine engine. It never downloads or installs runtime software.
public actor WineEngine {
    private var busyPrefixes: Set<String> = []
    private struct SteamSession {
        let runtime: Runtime
        let log: BoundedLog
        let htmlLog: URL
        let htmlLogSize: UInt64
        let showFPS: Bool
        let enableMetalFX: Bool
    }
    private var steamSessions: [String: SteamSession] = [:]
    private var steamCommands: Set<String> = []
    private var stoppingPrefixes: Set<String> = []
    private let graphicsRoot: URL?
    private let initializationTimeout: TimeInterval
    private let steamLauncher: URL
    public init(graphicsRoot: URL? = nil) {
        self.graphicsRoot = graphicsRoot
        self.initializationTimeout = 120
        self.steamLauncher = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Steam/steamwebhelper.exe")
    }

    /// Shorter deadlines permit deterministic timeout tests without running Wine.
    init(graphicsRoot: URL? = nil, initializationTimeout: TimeInterval, steamLauncher: URL? = nil) {
        self.graphicsRoot = graphicsRoot
        self.initializationTimeout = max(0.05, min(120, initializationTimeout))
        self.steamLauncher = steamLauncher ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Steam/steamwebhelper.exe")
    }

    public nonisolated static func discoverRuntimes() -> [WineRuntime] {
        let bundled = try? RuntimeLocation.resolve(reference: "portico-bundled://" + RuntimeCatalog.wine.id)
        #if APP_STORE
        guard let bundled, DistributionPolicy.permitsRuntime(at: bundled) else { return [] }
        return [WineRuntime(name: L10n.text("Wine у складі застосунку"), executableURL: bundled)]
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [(String, String)] = []
        if let bundled { candidates.append((L10n.text("Wine у складі застосунку"), bundled.path)) }
        candidates += [
            ("Wine Stable", "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine"),
            ("Wine Stable", "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine64"),
            ("Wine Stable", "\(home)/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine"),
            ("Wine Stable", "\(home)/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine64"),
            ("Wine", "/opt/homebrew/bin/wine"), ("Wine 64", "/opt/homebrew/bin/wine64"),
            ("Wine", "/usr/local/bin/wine"), ("Wine 64", "/usr/local/bin/wine64"),
            (L10n.text("Game Porting Toolkit (встановлено)"), "/usr/local/opt/game-porting-toolkit/bin/wine"),
            (L10n.text("Game Porting Toolkit (встановлено)"), "/opt/homebrew/opt/game-porting-toolkit/bin/wine"),
            (L10n.text("Game Porting Toolkit (встановлено)"), "/usr/local/opt/game-porting-toolkit/bin/wine64"),
            (L10n.text("Game Porting Toolkit (встановлено)"), "/opt/homebrew/opt/game-porting-toolkit/bin/wine64")
        ]
        var seen: Set<String> = []
        return candidates.compactMap { name, path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: path),
                  seen.insert(url.resolvingSymlinksInPath().path).inserted else { return nil }
            return WineRuntime(name: name, executableURL: url)
        }
        #endif
    }

    public func probe(executable: URL) async throws -> String {
        let engine = try Self.validateExecutable(executable)
        let managed = try GraphicsRuntimeLocation.rootDirectory(rootURL: graphicsRoot)
            .appendingPathComponent(GraphicsRuntimeCatalog.appleGPTK3.id + "/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64")
        if engine.standardizedFileURL == managed.standardizedFileURL ||
            engine.resolvingSymlinksInPath() == managed.resolvingSymlinksInPath() {
            _ = try GraphicsRuntimeLocation.resolve(
                reference: GraphicsRuntimeLocation.reference(providerID: GraphicsRuntimeCatalog.appleGPTK3.id), rootURL: graphicsRoot)
        }
        // The actual bounded process launch is authoritative. Static spctl signature
        // assessment can reject an app after the user approved it in macOS settings.
        // Neither quarantine attributes nor an application flag grant permission here.
        let runtime = try Self.validatedRuntime(at: engine)
        let result = try await ProcessRunner.run(executable: engine, arguments: ["--version"],
            environment: Self.runtimeEnvironment(runtime), workingDirectory: nil, log: nil, timeout: 8)
        try Self.requireSuccess(result)
        let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"(?im)^wine-[0-9]+(?:[.\s(-]|$)"#, options: .regularExpression) != nil else {
            throw PorticoError.runtimeUnavailable(L10n.text("Вибраний файл не повідомив версію Wine. Виберіть виконуваний файл wine або wine64 з повного встановлення."))
        }
        return version
    }

    public func initialize(bottle: Bottle, prefix: URL, logURL: URL, verbose: Bool) async throws -> ProcessResult {
        guard bottle.status != .ready else { throw PorticoError.invalidInput(L10n.text("Середовище вже створено.")) }
        let runtime = try await runtime(bottle: bottle)
        let key = try acquire(prefix)
        defer { busyPrefixes.remove(key) }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let log = try BoundedLog(url: logURL)
        let result = try await execute(runtime: runtime, arguments: ["wineboot.exe", "-u"],
            prefix: prefix, directory: nil, verbose: verbose, log: log, timeout: initializationTimeout)
        try Self.validatePrefix(prefix)
        return result
    }

    public func install(installer: URL, bottle: Bottle, prefix: URL, logURL: URL, verbose: Bool) async throws -> ProcessResult {
        try Self.validateReady(bottle, prefix: prefix)
        try Self.validateWindowsFile(installer, extensions: ["exe", "msi"])
        let args = installer.pathExtension.lowercased() == "msi"
            ? ["msiexec.exe", "/i", installer.path] : [installer.path]
        return try await perform(bottle: bottle, prefix: prefix, arguments: args,
            directory: installer.deletingLastPathComponent(), logURL: logURL, verbose: verbose)
    }

    public func launch(game: Game, bottle: Bottle, prefix: URL, logURL: URL, verbose: Bool, showFPS: Bool = false) async throws -> ProcessResult {
        try Self.validateReady(bottle, prefix: prefix)
        guard game.bottleID == bottle.id else { throw PorticoError.invalidInput(L10n.text("Гра належить до іншого середовища.")) }
        if game.effectiveLaunchMethod == .crossOver {
            throw PorticoError.invalidInput(L10n.text("Ярлик CrossOver відкривається через macOS, а не через Wine."))
        }
        if game.effectiveLaunchMethod == .steam {
            let appID = try SteamAction.validatedAppID(game.steamAppID ?? "")
            return try await steam(action: .run(appID: appID), bottle: bottle, prefix: prefix, logURL: logURL, verbose: verbose, showFPS: showFPS,
                enableMetalFX: game.effectiveMetalFXEnabled && MetalFX.isSupported(game: game, bottle: bottle))
        }
        try game.validateLaunchConfiguration()
        let executable = URL(fileURLWithPath: game.executablePath)
        let directory = game.workingDirectory.map { URL(fileURLWithPath: $0) } ?? executable.deletingLastPathComponent()
        return try await perform(bottle: bottle, prefix: prefix, arguments: [executable.path] + game.arguments,
            directory: directory, logURL: logURL, verbose: verbose, showFPS: showFPS,
            enableMetalFX: game.effectiveMetalFXEnabled && MetalFX.isSupported(game: game, bottle: bottle))
    }

    /// Applies per-executable graphics to any Steam or standalone game. The backup
    /// is written before registry mutation, so Auto can recover interrupted setup.
    public func prepareGameGraphics(game: Game, bottle: Bottle, prefix: URL, logURL: URL,
                                    verbose: Bool, legacyArchive: URL? = nil) async throws {
        guard !DistributionPolicy.isAppStore, game.effectiveLaunchMethod != .crossOver else {
            throw PorticoError.invalidInput(L10n.text("Цей компонент недоступний у профілі App Store."))
        }
        try Self.validateReady(bottle, prefix: prefix)
        guard game.bottleID == bottle.id else { throw PorticoError.invalidInput(L10n.text("Гра належить до іншого середовища.")) }
        let runtime = try await runtime(bottle: bottle)
        let key = try Self.prefixKey(prefix)
        guard !stoppingPrefixes.contains(key), !steamCommands.contains(key) else { throw PorticoError.busy }
        let session = steamSessions[key]
        if let session {
            guard Self.steamReady(session), session.runtime.wine == runtime.wine else { throw PorticoError.busy }
        } else { _ = try acquire(prefix) }
        steamCommands.insert(key)
        defer {
            steamCommands.remove(key)
            if session == nil { busyPrefixes.remove(key) }
        }
        let log = try session?.log ?? BoundedLog(url: logURL)
        let environment = Self.environment(runtime, prefix: prefix, verbose: verbose)
        var snapshot = try GameGraphics.readSnapshot(gameID: game.id, prefix: prefix)
        let target = game.effectiveGraphicsProfile == .automatic ? nil : try GameGraphics.targetExecutable(game: game, prefix: prefix)
        if game.effectiveGraphicsProfile == .directX9 && target == nil {
            throw PorticoError.invalidInput(L10n.text("Виберіть .exe гри в налаштуваннях графіки та збережіть конфігурацію."))
        }
        if let target { try GameGraphics.checkOwnership(executable: target, gameID: game.id, prefix: prefix) }
        let processes = try await ProcessRunner.run(executable: runtime.wine, arguments: ["tasklist", "/fo", "csv", "/nh"],
            environment: environment, workingDirectory: nil, log: nil, timeout: 15)
        try Self.requireSuccess(processes)
        let names = [target, snapshot?.executable].compactMap { $0?.lastPathComponent.lowercased() }
        if processes.output.components(separatedBy: .newlines).contains(where: { line in
            names.contains { line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("\"\($0)\",") }
        }) {
            throw PorticoError.invalidInput(L10n.text("Закрийте гру перед налаштуванням графіки. Steam можна залишити відкритим."))
        }

        func query(_ executable: URL) async throws -> [String: String] {
            let result = try await ProcessRunner.run(executable: runtime.wine,
                arguments: ["reg", "query", GameGraphics.registryKey(for: executable)],
                environment: environment, workingDirectory: nil, log: log, timeout: 15)
            // Wine reg uses 1 for an absent AppDefaults key.
            guard result.exitCode == 0 || result.exitCode == 1 else { try Self.requireSuccess(result); return [:] }
            return try GameGraphics.parseQuery(result.output)
        }
        func importValues(_ values: [String: String?], for executable: URL) async throws {
            guard !values.isEmpty else { return }
            let file = prefix.appendingPathComponent(".portico-graphics-\(UUID().uuidString).reg")
            defer { try? FileManager.default.removeItem(at: file) }
            func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            var contents = "Windows Registry Editor Version 5.00\r\n\r\n[" +
                GameGraphics.registryKey(for: executable).replacingOccurrences(of: "HKCU\\", with: "HKEY_CURRENT_USER\\") + "]\r\n"
            for name in values.keys.sorted() {
                let value = values[name]!
                contents += quoted(name) + "=" + (value.map(quoted) ?? "-") + "\r\n"
            }
            var data = Data([0xff, 0xfe]); data.append(contents.data(using: .utf16LittleEndian)!)
            try data.write(to: file, options: .atomic)
            let result = try await ProcessRunner.run(executable: runtime.wine, arguments: ["reg", "import", file.path],
                environment: environment, workingDirectory: nil, log: log, timeout: 30)
            try Self.requireSuccess(result)
        }
        if let old = snapshot, old.executablePath != target?.path {
            let current = try await query(old.executable)
            var restore: [String: String?] = [:]
            for (name, value) in GameGraphics.overrides where current[name] == value {
                // Keep changes made by the user after Portico's preparation.
                restore.updateValue(old.previous[name], forKey: name)
            }
            try await importValues(restore, for: old.executable)
            let restored = try await query(old.executable)
            for (name, value) in restore where restored[name] != value {
                throw PorticoError.storage(L10n.text("Не вдалося підтвердити налаштування графіки. Застосуйте конфігурацію ще раз."))
            }
            try FileManager.default.removeItem(at: GameGraphics.snapshotURL(gameID: game.id, prefix: prefix))
            snapshot = nil
        }
        guard let target else { return }
        if let legacyArchive {
            let staging = prefix.appendingPathComponent("drive_c/portico-directx-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            let installer = try await DirectXLegacyRuntime.extract(legacyArchive, to: staging)
            log.append(Data("[Portico] Open Microsoft DirectX setup. Complete the installer window to continue.\n".utf8))
            let result = try await ProcessRunner.run(executable: runtime.wine, arguments: [installer.path],
                environment: environment, workingDirectory: staging, log: log, timeout: 600)
            if result.exitCode != 3010 { try Self.requireSuccess(result) }
        }
        if snapshot == nil {
            snapshot = GameGraphics.Snapshot(gameID: game.id, executablePath: target.path,
                previous: try await query(target), complete: false)
        }
        snapshot!.complete = false
        try GameGraphics.writeSnapshot(snapshot!, prefix: prefix)
        try await importValues(GameGraphics.overrides.mapValues { Optional($0) }, for: target)
        guard try await query(target) == GameGraphics.overrides else {
            throw PorticoError.storage(L10n.text("Не вдалося підтвердити налаштування графіки. Застосуйте конфігурацію ще раз."))
        }
        snapshot!.complete = true
        try GameGraphics.writeSnapshot(snapshot!, prefix: prefix)
        log.append(Data("[Portico] DirectX 9 profile applied to \(target.lastPathComponent).\n".utf8))
    }

    public func configure(bottle: Bottle, prefix: URL, logURL: URL, verbose: Bool) async throws -> ProcessResult {
        try Self.validateReady(bottle, prefix: prefix)
        return try await perform(bottle: bottle, prefix: prefix, arguments: ["winecfg.exe"],
            directory: nil, logURL: logURL, verbose: verbose)
    }

    /// Runs a bounded, windowless capability probe only in an idle, ready prefix.
    /// The preflight waiter never terminates an already running Wine session.
    public func diagnoseGraphics(bottle: Bottle, prefix: URL, probeURL: URL,
                                 logURL: URL, verbose: Bool) async throws -> GraphicsCapabilities {
        try Self.validateReady(bottle, prefix: prefix)
        try Self.validateWindowsFile(probeURL, extensions: ["exe"])
        let runtime = try await runtime(bottle: bottle)
        let key = try acquire(prefix)
        defer { busyPrefixes.remove(key) }
        var environment = Self.environment(runtime, prefix: prefix, verbose: false)
        // Keep capability output in the bounded result tail; loader tracing can be
        // much larger than the probe itself. Exceptions remain available on request.
        environment["WINEDEBUG"] = verbose ? "-all,+seh" : "-all"
        environment["WINEDLLOVERRIDES"] = (environment["WINEDLLOVERRIDES"] ?? "winemenubuilder.exe=d") + ";winedbg.exe=d"
        let log = try BoundedLog(url: logURL)
        do {
            let idle = try await ProcessRunner.run(executable: runtime.server, arguments: ["-w"],
                environment: environment, workingDirectory: nil, log: log, timeout: 2)
            try Self.requireSuccess(idle)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Only our waiter was terminated. Do not run -k for an existing session.
            log.append(Data(L10n.text("[Portico] Закрийте програми в середовищі перед перевіркою DirectX 12.\n").utf8))
            throw PorticoError.busy
        }
        try Task.checkCancellation()
        let runner = ProcessRunner()
        log.append(Data("[Portico] DirectX 12 probe: \(runtime.wine.path)\n".utf8))
        let outcome: Result<ProcessResult, Error>
        do {
            outcome = .success(try await runner.run(executable: runtime.wine, arguments: [probeURL.path],
                environment: environment, workingDirectory: probeURL.deletingLastPathComponent(),
                log: log, timeout: 30, keepOutputOpen: true))
        } catch { outcome = .failure(error) }
        // Cleanup outlives task cancellation and precedes releasing the prefix lock.
        // It is reached only after the preflight confirmed that this session was idle.
        let cleanupEnvironment = environment
        let cleanup = Task.detached {
            try await Self.stopAndWait(runtime: runtime, environment: cleanupEnvironment, log: log)
        }
        let cleaned = await cleanup.result
        await runner.closeOutput()
        _ = try cleaned.get()
        try Task.checkCancellation()
        let result = try outcome.get()
        log.append(Data("\n[Portico] DirectX 12 probe exit: \(result.exitCode). Session stopped.\n".utf8))
        try Self.requireSuccess(result)
        return try GraphicsCapabilities.parse(result.output)
    }

    /// The first call owns the client session until all prefix processes exit. Further
    /// commands may reach that same client without waiting for it to close or replacing
    /// its log. Ordinary installers and configuration still obey the prefix lock.
    public func steam(action: SteamAction, bottle: Bottle, prefix: URL, logURL: URL, verbose: Bool, existingSessionOnly: Bool = false, showFPS: Bool = false, enableMetalFX: Bool? = nil) async throws -> ProcessResult {
        try Self.validateReady(bottle, prefix: prefix)
        let uri = try action.uri
        let runtime = try await runtime(bottle: bottle)
        let key = try Self.prefixKey(prefix)
        guard !stoppingPrefixes.contains(key) else { throw PorticoError.busy }
        guard let executable = SteamSupport.executable(in: prefix) else {
            throw PorticoError.invalidInput(L10n.text("Клієнт Steam для Windows не знайдено в цьому середовищі. Встановіть його з розділу Steam."))
        }
        try Self.validateWindowsFile(executable, extensions: ["exe"])
        // A URI can race the first client's startup. Keep compatibility flags on
        // every invocation so the winning process cannot start with plain CEF.
        let wineForgeSteam = bottle.steamDesktop == true && runtime.graphicsProviderID != nil && runtime.wine.lastPathComponent == "wine"
        let legacyDesktop = bottle.steamDesktop == true && !wineForgeSteam
        var clientFlags = legacyDesktop ? ["-noverifyfiles", "-cef-disable-gpu"] : []
        // Current CEF aborts while initializing its Windows sandbox on WineForge.
        // Scope this compatibility option to the opted-in Steam client only.
        if wineForgeSteam {
            clientFlags.append("-cef-disable-sandbox")
        }
        let arguments = [executable.path] + clientFlags + [uri]
        if let session = steamSessions[key] {
            if case .run = action, session.enableMetalFX != (enableMetalFX ?? false) {
                throw PorticoError.invalidInput(L10n.text("Перезапустіть Steam у цьому середовищі, щоб застосувати режим DLSS → MetalFX для гри."))
            }
            if case .run = action, session.showFPS != showFPS {
                throw PorticoError.invalidInput(L10n.text("Перезапустіть Steam у цьому середовищі, щоб застосувати налаштування лічильника FPS."))
            }
            guard session.runtime.wine.resolvingSymlinksInPath() == runtime.wine.resolvingSymlinksInPath(),
                  Self.steamReady(session),
                  steamCommands.insert(key).inserted else { throw PorticoError.busy }
            defer { steamCommands.remove(key) }
            session.log.append(Data("\n[Portico] Steam: \(uri)\n".utf8))
            let result = try await ProcessRunner.run(executable: runtime.wine, arguments: arguments,
                environment: MetalFX.applying(enabled: session.enableMetalFX, to: Self.environment(runtime, prefix: prefix, verbose: verbose)),
                workingDirectory: executable.deletingLastPathComponent(), log: session.log, timeout: 20)
            // A failed navigation command must not stop an existing download or game.
            if !(result.exitCode == 42 && result.output.contains("Update complete, launching Steam")) {
                try Self.requireSuccess(result)
            }
            return result
        }
        guard !existingSessionOnly else {
            throw PorticoError.invalidInput(L10n.text("Сеанс Steam завершився. Відкрийте Steam знову."))
        }
        // A client left running outside this host cannot inherit new launch settings.
        if bottle.graphics?.backend == .d3dMetal {
            do {
                let idle = try await ProcessRunner.run(executable: runtime.server, arguments: ["-w"],
                    environment: Self.environment(runtime, prefix: prefix, verbose: false),
                    workingDirectory: nil, log: nil, timeout: 1)
                try Self.requireSuccess(idle)
            } catch is CancellationError { throw CancellationError() }
            catch {
                throw PorticoError.invalidInput(L10n.text("Закрийте Steam та інші програми цього середовища, потім запустіть гру з Portico, щоб застосувати режим DLSS → MetalFX."))
            }
        }
        _ = try acquire(prefix)
        defer { steamSessions[key] = nil; busyPrefixes.remove(key) }
        if legacyDesktop {
            // Do not replace a helper belonging to an externally running client.
            let idle = try await ProcessRunner.run(executable: runtime.server, arguments: ["-w"],
                environment: Self.environment(runtime, prefix: prefix, verbose: false),
                workingDirectory: nil, log: nil, timeout: 1)
            try Self.requireSuccess(idle)
            try SteamCompatibility.prepare(client: executable, prefix: prefix,
                launcher: steamLauncher)
        }
        let log = try BoundedLog(url: logURL)
        let htmlLog = executable.deletingLastPathComponent().appendingPathComponent("logs/steamui_html.txt")
        let htmlLogSize = (try? htmlLog.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let metalFX = enableMetalFX == true && bottle.graphics?.backend == .d3dMetal
        steamSessions[key] = SteamSession(runtime: runtime, log: log, htmlLog: htmlLog, htmlLogSize: htmlLogSize, showFPS: showFPS, enableMetalFX: metalFX)
        // Start the desktop only for a new session. Navigation commands above must
        // reach the existing Steam process without creating another desktop.
        let startupArguments = legacyDesktop
            ? ["explorer.exe", "/desktop=PorticoSteam,1280x800"] + arguments
            : arguments
        return try await execute(runtime: runtime, arguments: startupArguments, prefix: prefix,
            directory: executable.deletingLastPathComponent(), verbose: verbose, log: log, allowSteamRestart: true, showFPS: showFPS, enableMetalFX: metalFX)
    }

    /// Only the selected prefix is stopped; no global killall/pkill is used.
    public func stop(bottle: Bottle, prefix: URL) async throws {
        let runtime = try await runtime(bottle: bottle)
        let key = try Self.prefixKey(prefix)
        guard stoppingPrefixes.insert(key).inserted else { throw PorticoError.busy }
        defer { stoppingPrefixes.remove(key) }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefix.path, isDirectory: &directory), directory.boolValue else {
            throw PorticoError.invalidInput(L10n.text("Папку середовища не знайдено."))
        }
        try await Self.stopAndWait(runtime: runtime,
            environment: Self.environment(runtime, prefix: prefix, verbose: false), log: nil)
    }

    public func isRunning(prefix: URL) -> Bool {
        guard let key = try? Self.prefixKey(prefix) else { return false }
        return busyPrefixes.contains(key)
    }

    public func isSteamReady(prefix: URL) -> Bool {
        guard let key = try? Self.prefixKey(prefix), let session = steamSessions[key] else { return false }
        return Self.steamReady(session)
    }

    private static func steamReady(_ session: SteamSession) -> Bool {
        guard session.htmlLog.standardizedFileURL == session.htmlLog.resolvingSymlinksInPath(),
              (try? session.htmlLog.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        guard let handle = try? FileHandle(forReadingFrom: session.htmlLog) else { return false }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let start = size < session.htmlLogSize ? 0 : session.htmlLogSize
            try handle.seek(toOffset: max(start, size > 65_536 ? size - 65_536 : 0))
            let data = try handle.read(upToCount: 65_536) ?? Data()
            return String(decoding: data, as: UTF8.self).contains("BrowserReady:")
        } catch { return false }
    }

    private func perform(bottle: Bottle, prefix: URL, arguments: [String], directory: URL?, logURL: URL, verbose: Bool, showFPS: Bool? = nil, enableMetalFX: Bool? = nil) async throws -> ProcessResult {
        let runtime = try await runtime(bottle: bottle)
        let key = try acquire(prefix)
        defer { busyPrefixes.remove(key) }
        let log = try BoundedLog(url: logURL)
        return try await execute(runtime: runtime, arguments: arguments, prefix: prefix,
            directory: directory, verbose: verbose, log: log, showFPS: showFPS, enableMetalFX: enableMetalFX)
    }

    private func execute(runtime: Runtime, arguments: [String], prefix: URL, directory: URL?, verbose: Bool,
                         log: BoundedLog, timeout: TimeInterval? = nil, allowSteamRestart: Bool = false, showFPS: Bool? = nil, enableMetalFX: Bool? = nil) async throws -> ProcessResult {
        var environment = Self.environment(runtime, prefix: prefix, verbose: verbose)
        if let showFPS { environment = FPSCounter.applying(enabled: showFPS, to: environment) }
        if let enableMetalFX {
            environment = MetalFX.applying(enabled: enableMetalFX, to: environment)
            log.append(Data("[Portico] DLSS → MetalFX: \(enableMetalFX ? "ON" : "OFF")\n".utf8))
        }
        log.append(Data(("[Portico] \(runtime.wine.path) \(arguments.map { String(reflecting: $0) }.joined(separator: " "))\n").utf8))
        let commandRunner = ProcessRunner()
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let command = try await commandRunner.run(executable: runtime.wine, arguments: arguments,
                environment: environment, workingDirectory: directory, log: log, timeout: timeout, keepOutputOpen: true)
            log.append(Data((L10n.text("\n[Portico] Wine завершився з кодом \(command.exitCode).\n")).utf8))
            let wait: ProcessResult
            let steamRestart = allowSteamRestart && command.exitCode == 42
                && command.output.contains("Update complete, launching Steam")
            if command.exitCode != 0 && !steamRestart {
                // Failed launchers may leave child processes behind. Stop only this
                // prefix, then bound the cleanup wait before reporting the failure.
                log.append(Data(L10n.text("[Portico] Зупинка процесів після помилки запуску.\n").utf8))
                wait = try await Self.stopAndWait(runtime: runtime, environment: environment, log: log)
            } else {
                let remaining = timeout.map { max(0.01, $0 - (ProcessInfo.processInfo.systemUptime - startedAt)) }
                wait = try await ProcessRunner.run(executable: runtime.server, arguments: ["-w"],
                    environment: environment, workingDirectory: nil, log: log, timeout: remaining)
            }
            await commandRunner.closeOutput()
            log.append(Data((L10n.text("[Portico] wineserver -w завершився з кодом \(wait.exitCode).\n")).utf8))
            let code = command.exitCode == 0 || steamRestart ? wait.exitCode : command.exitCode
            if code == 0 { log.append(Data(L10n.text("[Portico] Операцію завершено.\n").utf8)) }
            let result = ProcessResult(exitCode: code, output: log.tail)
            try Self.requireSuccess(result)
            return result
        } catch {
            if error is CancellationError || timeout != nil {
                // Bounded initialization can time out while wineboot is waiting for
                // a macOS prompt, or after it detached Wine children. Cleanup must
                // outlive task cancellation and finish before releasing the lock.
                let cleanup = Task.detached {
                    try await Self.stopAndWait(runtime: runtime, environment: environment, log: log)
                }
                if case .failure(let cleanupError) = await cleanup.result {
                    log.append(Data((L10n.text("\n[Portico] Не вдалося підтвердити зупинку середовища: \(cleanupError.localizedDescription)\n")).utf8))
                }
            }
            await commandRunner.closeOutput()
            throw error
        }
    }

    private func acquire(_ prefix: URL) throws -> String {
        let key = try Self.prefixKey(prefix)
        guard !stoppingPrefixes.contains(key), !steamCommands.contains(key),
              busyPrefixes.insert(key).inserted else { throw PorticoError.busy }
        return key
    }

    private struct Runtime: Sendable {
        let wine: URL
        let server: URL
        let graphicsProviderID: String?
    }

    /// Wine7.7 returns1 without output when -k finds no server. Accept that case
    /// only after the same paired server confirms an idle prefix with -w success.
    @discardableResult
    private static func stopAndWait(runtime: Runtime, environment: [String: String], log: BoundedLog?) async throws -> ProcessResult {
        let killed = try await ProcessRunner.run(executable: runtime.server, arguments: ["-k"],
            environment: environment, workingDirectory: nil, log: log, timeout: 10)
        if !(killed.exitCode == 1 && killed.output.isEmpty) { try requireSuccess(killed) }
        let waited = try await ProcessRunner.run(executable: runtime.server, arguments: ["-w"],
            environment: environment, workingDirectory: nil, log: log, timeout: 10)
        try requireSuccess(waited)
        return waited
    }

    private func runtime(bottle: Bottle) async throws -> Runtime {
        try bottle.graphics?.validate()
        if GraphicsRuntimeLocation.isGraphicsReference(bottle.enginePath) {
            guard let graphics = bottle.graphics, graphics.backend == .d3dMetal,
                  let providerID = graphics.providerID,
                  bottle.enginePath == (try GraphicsRuntimeLocation.reference(providerID: providerID)) else {
                throw PorticoError.runtimeUnavailable(L10n.text("Графічний рушій не відповідає налаштуванням середовища. Створіть нове середовище з потрібним рушієм."))
            }
            let location = try GraphicsRuntimeLocation.resolve(reference: bottle.enginePath, rootURL: graphicsRoot)
            return try Self.validatedRuntime(at: location, graphicsProviderID: providerID)
        }
        guard bottle.graphics?.backend != .d3dMetal else {
            throw PorticoError.runtimeUnavailable(L10n.text("Для D3DMetal потрібен окремий повний рушій GPTK. Наявне середовище Wine не можна перемкнути заміною DLL; створіть нове середовище DirectX 12."))
        }
        let location = try RuntimeLocation.resolve(reference: bottle.enginePath)
        return try Self.validatedRuntime(at: location)
    }

    private static func validatedRuntime(at location: URL, graphicsProviderID: String? = nil) throws -> Runtime {
        let wine = try validateExecutable(location)
        let resolved = wine.resolvingSymlinksInPath()
        let server = resolved.deletingLastPathComponent().appendingPathComponent("wineserver")
        guard DistributionPolicy.permitsRuntime(at: server),
              FileManager.default.isExecutableFile(atPath: server.path),
              server.resolvingSymlinksInPath().deletingLastPathComponent() == resolved.deletingLastPathComponent() else {
            throw PorticoError.runtimeUnavailable(L10n.text("Поруч із вибраним Wine не знайдено wineserver із того самого встановлення. Потрібен повний сумісний runtime, зокрема wineserver."))
        }
        return Runtime(wine: wine, server: server, graphicsProviderID: graphicsProviderID)
    }

    private static func validateExecutable(_ url: URL) throws -> URL {
        guard DistributionPolicy.permitsRuntime(at: url) else {
            throw PorticoError.runtimeUnavailable(L10n.text("Ця збірка використовує лише Wine всередині застосунку. Зовнішній рушій недоступний у профілі App Store."))
        }
        guard !url.pathComponents.contains(where: { $0.lowercased() == "crossover.app" }),
              !url.resolvingSymlinksInPath().pathComponents.contains(where: { $0.lowercased() == "crossover.app" }) else {
            throw PorticoError.runtimeUnavailable(L10n.text("CrossOver використовує власні середовища й поки не підтримується цим адаптером. Виберіть окреме встановлення Wine."))
        }
        var isDirectory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw PorticoError.runtimeUnavailable(L10n.text("Виконуваний файл Wine не знайдено: \(url.path)"))
        }
        return url
    }

    private static func prefixKey(_ prefix: URL) throws -> String {
        guard prefix.isFileURL else { throw PorticoError.invalidInput(L10n.text("Середовище має розташовуватися в локальній папці.")) }
        let canonical = prefix.standardizedFileURL.resolvingSymlinksInPath().path
        guard canonical != "/", canonical != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw PorticoError.invalidInput(L10n.text("Для середовища потрібна окрема папка."))
        }
        return canonical
    }

    private static func validatePrefix(_ prefix: URL) throws {
        _ = try prefixKey(prefix)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c").path, isDirectory: &directory),
              directory.boolValue, FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            throw PorticoError.invalidInput(L10n.text("Середовище не ініціалізовано: відсутній drive_c або system.reg. Створіть нове середовище."))
        }
    }

    private static func validateReady(_ bottle: Bottle, prefix: URL) throws {
        guard bottle.status == .ready else { throw PorticoError.invalidInput(L10n.text("Спочатку дочекайтеся успішного створення середовища.")) }
        try validatePrefix(prefix)
    }

    private static func validateWindowsFile(_ url: URL, extensions: Set<String>) throws {
        var directory: ObjCBool = false
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
            throw PorticoError.invalidInput(L10n.text("Виберіть наявний файл \(extensions.sorted().map { "." + $0 }.joined(separator: " / ")): \(url.path)"))
        }
    }

    private static func environment(_ runtime: Runtime, prefix: URL, verbose: Bool) -> [String: String] {
        var environment = runtimeEnvironment(runtime)
        environment["WINEPREFIX"] = prefix.standardizedFileURL.resolvingSymlinksInPath().path
        environment["WINEDEBUG"] = verbose ? "+timestamp,+pid,+tid,+seh,+loaddll" : "-all"
        return environment
    }

    private static func runtimeEnvironment(_ runtime: Runtime) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "WINEPREFIX")
        environment["WINESERVER"] = runtime.server.path
        environment["WINELOADER"] = runtime.wine.path
        environment["WINEDEBUG"] = "-all"
        environment["PATH"] = runtime.wine.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        if let providerID = runtime.graphicsProviderID {
            return GraphicsRuntimeLocation.applyingEnvironment(to: environment,
                executable: runtime.wine, providerID: providerID)
        }
        return BundledRuntimeEnvironment.applying(to: environment, executable: runtime.wine)
    }

    private static func requireSuccess(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else { throw PorticoError.processFailed(result.exitCode, result.output) }
    }
}

/// Serializes writes and retains only a bounded rolling log (2 MiB) and UI tail (32 KiB).
private final class BoundedLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    private var bytes = Data()
    private var written = 0
    private let maxBytes = 2 * 1024 * 1024
    private let tailBytes = 32 * 1024
    init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw PorticoError.storage(L10n.text("Не вдалося створити журнал: \(url.path)"))
            }
            handle = try FileHandle(forWritingTo: url)
        } else { handle = nil }
    }
    deinit { try? handle?.close() }
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        bytes.append(data)
        if bytes.count > tailBytes { bytes = Data(bytes.suffix(tailBytes)) }
        guard let handle else { return }
        do {
            if written + data.count > maxBytes {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                let retained = Data(bytes.suffix(tailBytes))
                try handle.write(contentsOf: retained)
                written = retained.count
            } else {
                try handle.write(contentsOf: data)
                written += data.count
            }
        } catch { /* Keep draining pipes even when the disk becomes unavailable. */ }
    }
    var tail: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Pipes are drained on a private queue with nonblocking reads. No waitUntilExit
/// or pipe read can block the main actor, and inherited child pipes cannot hang completion.
private final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let queue = DispatchQueue(label: "Portico.Wine.Process")
    private let output = Pipe()
    private let error = Pipe()
    private var sources: [DispatchSourceRead] = []
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var collector: BoundedLog!
    private var sharedLog: BoundedLog?
    private var completed = false
    private var keepOutputOpen = false
    private var timedOut = false
    private var cancelled = false
    private var timer: DispatchWorkItem?

    static func run(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?, log: BoundedLog?, timeout: TimeInterval?) async throws -> ProcessResult {
        try await ProcessRunner().run(executable: executable, arguments: arguments, environment: environment,
            workingDirectory: workingDirectory, log: log, timeout: timeout)
    }

    func run(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?, log: BoundedLog?, timeout: TimeInterval?, keepOutputOpen: Bool = false) async throws -> ProcessResult {
        let runner = self
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                runner.queue.async {
                    runner.keepOutputOpen = keepOutputOpen
                    runner.start(executable: executable, arguments: arguments, environment: environment,
                        workingDirectory: workingDirectory, log: log, timeout: timeout, continuation: continuation)
                }
            }
        } onCancel: { runner.queue.async { runner.cancel() } }
    }

    private func start(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL?, log: BoundedLog?, timeout: TimeInterval?, continuation: CheckedContinuation<ProcessResult, Error>) {
        self.continuation = continuation
        if cancelled { finish(error: CancellationError()); return }
        collector = try? BoundedLog(url: nil)
        sharedLog = log
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = output
        process.standardError = error
        for pipe in [output, error] {
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain(fd) }
            let handle = pipe.fileHandleForReading
            source.setCancelHandler { try? handle.close() }
            sources.append(source)
            source.resume()
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.didTerminate() }
        }
        do { try process.run() }
        catch { finish(error: error); return }
        if let timeout {
            let timer = DispatchWorkItem { [weak self] in
                guard let self, !self.completed else { return }
                self.timedOut = true
                self.terminate()
            }
            self.timer = timer
            queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        }
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        // Yield periodically so a very noisy process cannot starve cancellation.
        for _ in 0..<64 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            let data = Data(buffer.prefix(count))
            collector?.append(data)
            sharedLog?.append(data)
        }
    }

    private func didTerminate() {
        guard !completed else { return }
        drain(output.fileHandleForReading.fileDescriptor)
        drain(error.fileHandleForReading.fileDescriptor)
        if cancelled { finish(error: CancellationError()) }
        else if timedOut { finish(error: PorticoError.runtimeUnavailable(L10n.text("Wine не відповів вчасно; процес операції зупинено. Перевірте системні вікна macOS і журнал."))) }
        else { finish(result: ProcessResult(exitCode: process.terminationStatus, output: collector.tail)) }
    }

    private func cancel() {
        cancelled = true
        guard continuation != nil, !completed else { return }
        terminate()
    }

    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.completed, self.process.isRunning else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }

    func closeOutput() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closePipes()
                continuation.resume()
            }
        }
    }

    private func closePipes() {
        guard !sources.isEmpty else { return }
        drain(output.fileHandleForReading.fileDescriptor)
        drain(error.fileHandleForReading.fileDescriptor)
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    private func finish(result: ProcessResult? = nil, error: Error? = nil) {
        guard !completed else { return }
        completed = true
        timer?.cancel()
        process.terminationHandler = nil
        if !keepOutputOpen { closePipes() }
        if let error { continuation?.resume(throwing: error) }
        else if let result { continuation?.resume(returning: result) }
        continuation = nil
    }
}
