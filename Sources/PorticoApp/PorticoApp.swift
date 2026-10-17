import SwiftUI
import AppKit
import PorticoCore

@main
struct PorticoApp: App {
    @NSApplicationDelegateAdaptor(PorticoAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .environment(\.locale, model.language.locale)
                .frame(minWidth: 1080, minHeight: 730)
                .preferredColorScheme(model.theme == .dark ? .dark : .light)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 830)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("Налаштування")) { model.section = .settings }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("Додати гру…")) { model.sheet = .addGame }
                    .keyboardShortcut("n")
                    .disabled(model.readyBottles.isEmpty)
                Button(L10n.text("Створити середовище…")) {
                    if model.engineReady { model.sheet = .createBottle }
                    else { model.sheet = .runtimeSetup }
                }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button(CrashReportText.text("Повідомити про збій…", "Report a crash…")) { NotificationCenter.default.post(name: CrashReportText.openNotification, object: nil) }
                Button(CrashReportText.text("Запропонувати ідею…", "Suggest an idea…")) { NotificationCenter.default.post(name: CrashReportText.openNotification, object: FeedbackKind.suggestion) }
                Link(CrashReportText.text("Збої та пропозиції на сайті", "Crashes and suggestions online"), destination: CrashReporting.boardURL(kind: .crash))
                Button(L10n.text("Як налаштувати Portico")) { model.section = .setup }
            }
        }
    }
}

@MainActor
final class PorticoAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationWillTerminate(_ notification: Notification) { model?.cooling.stop() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.operations.isEmpty || model.activeDownload != nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L10n.text("Зупинити програми й вийти?")
        alert.informativeText = model.operations.isEmpty
            ? L10n.text("Завантаження або підготовку рушія ще не завершено. Вихід скасує поточну операцію.")
            : L10n.text("У середовищах ще працюють ігри, Steam або інсталятори. Вихід зупинить їх і поточні завантаження. Збережіть ігровий прогрес перед виходом.")
        alert.addButton(withTitle: L10n.text("Продовжити роботу"))
        alert.addButton(withTitle: L10n.text("Зупинити й вийти"))
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        Task { sender.reply(toApplicationShouldTerminate: await model.stopAllForExit()) }
        return .terminateLater
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case library, steam, bottles, runtime, logs, setup, settings
    var title: String {
        switch self {
        case .library: return L10n.text("Бібліотека")
        case .steam: return "Steam"
        case .bottles: return L10n.text("Середовища")
        case .runtime: return L10n.text("Рушій")
        case .logs: return L10n.text("Журнал")
        case .settings: return L10n.text("Налаштування")
        case .setup: return L10n.text("Початок роботи")
        }
    }
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .steam: return "gamecontroller"
        case .bottles: return "shippingbox"
        case .runtime: return "cpu"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape"
        case .setup: return "list.bullet.clipboard"
        }
    }
}

enum AppSheet: Identifiable {
    case createBottle, addGame, runtimeSetup, graphicsSetup, crossOverImport
    case editGame(UUID)
    case gameParameters(UUID)
    case launchGuide(Game)
    case removeGame(GameRemovalTarget)
    var id: String {
        switch self {
        case .createBottle: return "createBottle"
        case .addGame: return "addGame"
        case .runtimeSetup: return "runtimeSetup"
        case .graphicsSetup: return "graphicsSetup"
        case .crossOverImport: return "crossOverImport"
        case .editGame(let id): return "editGame-\(id)"
        case .gameParameters(let id): return "gameParameters-\(id)"
        case .launchGuide(let game): return "launchGuide-\(game.id)"
        case .removeGame(let target): return "removeGame-\(target.id)"
        }
    }
}

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var reportable = false
}

@MainActor
final class AppModel: ObservableObject {
    let cooling = CoolingController()
    @Published var theme: AppTheme = .saved() {
        didSet { theme.save() }
    }
    @Published var language: AppLanguage = .saved() {
        didSet {
            language.save()
            refreshRuntimes()
            refreshLog()
        }
    }
    @Published var library = Library()
    @Published var section: AppSection = .library
    @Published var selectedGalleryGameID: String?
    @Published var sheet: AppSheet?
    @Published var notice: Notice?
    @Published var runtimes: [WineRuntime] = []
    @Published var enginePathDraft = ""
    @Published var engineVersion = ""
    @Published var validatedEnginePath: String?
    @Published var isProbing = false
    @Published var operations: [UUID: LocalizedMessage] = [:]
    @Published var runningGames: [UUID: UUID] = [:]
    @Published var logBottleID: UUID?
    @Published var logText = ""
    @Published var storageProblem: String?
    @Published var filter: GameFilter = .all
    @Published var search = ""
    @Published var setupProgress: InstallProgress?
    @Published var setupError: LocalizedMessage?
    @Published var downloadedWineApp: URL?
    @Published var downloadedGStreamer: URL?
    @Published var activeDownload: String?
    @Published var setupFinished = false
    @Published var hasShownSetup = false
    @Published var steamSessions: Set<UUID> = []
    @Published var steamStarting: Set<UUID> = []
    @Published var steamCommands: Set<UUID> = []
    @Published var steamInstallerDownloads: Set<UUID> = []
    @Published var steamClients: [UUID: URL] = [:]
    @Published var steamInstalledGames: [UUID: [SteamInstalledGame]] = [:]
    @Published var steamMessages: [UUID: LocalizedMessage] = [:]
    @Published var steamScanErrors: [UUID: String] = [:]
    @Published var crossOverLaunchRequests: Set<UUID> = []
    @Published var crossOverRequestedGames: Set<UUID> = []
    @Published var preparingGames: Set<UUID> = []
    @Published var preparedGames: Set<UUID> = []
    @Published var removingGames: Set<UUID> = []
    @Published var gamePreparationErrors: [UUID: String] = [:]
    @Published var gamePreparationProgress: [UUID: InstallProgress] = [:]
    var hasShownGraphicsWelcome = false
    @Published var graphicsInstalled = false
    @Published var graphicsProviderID = GraphicsRuntimeCatalog.appleGPTK3.id
    @Published var localGraphicsPath: String?
    @Published var graphicsExecutionAllowed = false
    @Published var assessingGraphics = false
    @Published var graphicsSecurityIssue: String?
    @Published var graphicsError: String?
    @Published var graphicsReports: [UUID: GraphicsCapabilities] = [:]
    @Published var newBottleGraphics: GraphicsBackend = .wineDefault
    var newGameBottleID: UUID?
    private(set) var isUISimulation = false
    var setupTask: Task<Void, Never>?
    let runtimeInstaller = RuntimeInstaller()
    let engine: WineEngine
    let steamSupport = SteamSupport()
    private(set) var store: LibraryStore?
    private var stoppingBottles: Set<UUID> = []
    private var stopCommands: Set<UUID> = []
    private var operationTasks: [UUID: Task<Void, Never>] = [:]
    private var steamCommandTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        do {
            #if DEBUG
            let overrideRoot = ProcessInfo.processInfo.environment["PORTICO_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            let storage = try LibraryStore(rootURL: overrideRoot)
            #else
            let storage = try LibraryStore()
            #endif
            let saved = try storage.load()
            store = storage
            library = saved
            enginePathDraft = saved.settings.enginePath
            #if DEBUG
            isUISimulation = FileManager.default.fileExists(atPath:
                storage.rootURL.appendingPathComponent(".portico-smoke-fixture").path)
            #endif
        } catch {
            storageProblem = error.localizedDescription
            notice = Notice(title: L10n.text("Не вдалося відкрити бібліотеку"), message: error.localizedDescription, reportable: true)
        }
        engine = WineEngine(graphicsRoot: store?.rootURL.appendingPathComponent("Graphics", isDirectory: true))
        runtimes = WineEngine.discoverRuntimes()
        if !enginePathDraft.isEmpty {
            do { enginePathDraft = try RuntimeLocation.resolve(reference: enginePathDraft).path }
            catch { notice = Notice(title: L10n.text("Не вдалося виконати дію"), message: error.localizedDescription, reportable: true) }
        }
        if DistributionPolicy.isAppStore && !enginePathDraft.hasPrefix("portico-bundled://") {
            enginePathDraft = DistributionPolicy.bundledWineURL.path
        }
        if enginePathDraft.isEmpty { enginePathDraft = runtimes.first?.executableURL.path ?? "" }
    }

    var readyBottles: [Bottle] { library.bottles.filter { $0.status == .ready } }
    var engineReady: Bool { validatedEnginePath != nil && validatedEnginePath == enginePathDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var filteredGames: [Game] {
        library.games.filter { game in
            (search.isEmpty || game.name.localizedCaseInsensitiveContains(search)) &&
            (filter != .favorites || game.isFavorite) &&
            (filter != .recent || game.lastPlayedAt != nil)
        }.sorted {
            if filter == .recent { return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
            return $0.addedAt > $1.addedAt
        }
    }
    func bottle(for game: Game) -> Bottle? { library.bottles.first { $0.id == game.bottleID } }
    func isBusy(_ bottle: Bottle) -> Bool { operations[bottle.id] != nil }
    func isStopping(_ bottle: Bottle) -> Bool { stoppingBottles.contains(bottle.id) }

    @discardableResult
    func commit(_ next: Library) -> Bool {
        guard let store, storageProblem == nil else {
            notice = Notice(title: L10n.text("Бібліотека недоступна"), message: storageProblem ?? L10n.text("Не вдалося відкрити сховище."), reportable: true)
            return false
        }
        do { try store.save(next); library = next; return true }
        catch { show(error); return false }
    }
    func show(_ error: Error) { notice = Notice(title: L10n.text("Не вдалося виконати дію"), message: error.localizedDescription, reportable: true) }
    func refreshRuntimes() { runtimes = WineEngine.discoverRuntimes() }

    func chooseEngine() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Виберіть виконуваний файл wine")
        panel.message = L10n.text("Зазвичай він розташований усередині застосунку рушія: Contents → Resources → wine → bin → wine.")
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { enginePathDraft = url.path; Task { await probeEngine() } }
    }
    func probeEngine() async {
        guard !isProbing else { return }
        isProbing = true
        validatedEnginePath = nil
        engineVersion = ""
        defer { isProbing = false }
        let path = NSString(string: enginePathDraft.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        do {
            guard !path.isEmpty else { throw PorticoError.invalidInput(L10n.text("Виберіть виконуваний файл Wine.")) }
            let executable = try RuntimeLocation.resolve(reference: path)
            let reference = try RuntimeLocation.reference(for: executable)
            let version = try await engine.probe(executable: executable)
            var next = library
            next.settings.enginePath = reference
            guard commit(next) else { return }
            enginePathDraft = executable.path
            validatedEnginePath = executable.path
            engineVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError { }
        catch { show(error) }
    }
    func setShowFPS(_ enabled: Bool) {
        var next = library; next.settings.showFPS = enabled; commit(next)
    }
    func setVerbose(_ enabled: Bool) {
        var next = library; next.settings.verboseLogging = enabled; commit(next)
    }

    func createBottle(name: String, graphics: GraphicsBackend = .wineDefault) {
        guard let store else { return }
        let reference: String
        do {
            if graphics == .d3dMetal {
                guard graphicsExecutionAllowed else { sheet = .graphicsSetup; return }
                reference = try GraphicsRuntimeLocation.reference(providerID: graphicsProviderID)
                _ = try GraphicsRuntimeLocation.resolve(reference: reference, rootURL: graphicsRoot)
            } else {
                guard engineReady, let runtime = validatedEnginePath else { section = .runtime; return }
                reference = try RuntimeLocation.reference(for: URL(fileURLWithPath: runtime))
            }
        }
        catch { show(error); return }
        let configuration = graphics == .d3dMetal
            ? BottleGraphics(backend: .d3dMetal, providerID: graphicsProviderID) : nil
        let bottle = Bottle(name: name.trimmingCharacters(in: .whitespacesAndNewlines), enginePath: reference, graphics: configuration)
        var next = library
        next.bottles.append(bottle)
        guard commit(next) else { return }
        sheet = nil
        if section != .setup { section = .bottles }
        initialize(bottle, store: store)
    }
    func retryBottle(_ bottle: Bottle) {
        guard let store, !isBusy(bottle), bottle.status == .failed else { return }
        var next = library
        guard let i = next.bottles.firstIndex(where: { $0.id == bottle.id }) else { return }
        next.bottles[i].status = .creating
        guard commit(next) else { return }
        initialize(next.bottles[i], store: store)
    }
    private func initialize(_ bottle: Bottle, store: LibraryStore) {
        operations[bottle.id] = "Підготовка середовища Windows…"
        logBottleID = bottle.id
        operationTasks[bottle.id] = Task {
            do {
                _ = try await engine.initialize(bottle: bottle, prefix: store.prefixURL(for: bottle), logURL: store.logURL(for: bottle), verbose: library.settings.verboseLogging)
                if bottle.graphics?.backend == .d3dMetal {
                    operations[bottle.id] = "Перевірка DirectX 12…"
                    var ready = bottle; ready.status = .ready
                    let report = try await runGraphicsProbe(in: ready)
                    guard report.supportsDX12FeatureLevel12 else {
                        throw PorticoError.runtimeUnavailable(L10n.text("Перевірка на цьому Mac не підтвердила Feature Level 12_0. Відкрийте журнал діагностики."))
                    }
                }
                try Task.checkCancellation()
                setBottleStatus(bottle.id, .ready)
            } catch {
                setBottleStatus(bottle.id, .failed)
                if !stoppingBottles.contains(bottle.id) { show(error) }
            }
            operations[bottle.id] = nil; operationTasks[bottle.id] = nil; stoppingBottles.remove(bottle.id); refreshLog()
        }
    }
    private func setBottleStatus(_ id: UUID, _ status: BottleStatus) {
        var next = library
        if let i = next.bottles.firstIndex(where: { $0.id == id }) {
            next.bottles[i].status = status
            if !commit(next) {
                // The process has ended even if the disk cannot accept the result.
                // Keep Retry available; the next successful save persists recovery.
                library.bottles[i].status = .failed
            }
        }
    }

    func diagnoseGraphics(in bottle: Bottle) {
        guard bottle.status == .ready, !isBusy(bottle) else { return }
        operations[bottle.id] = "Перевірка DirectX 12…"
        logBottleID = bottle.id
        operationTasks[bottle.id] = Task {
            defer {
                operations[bottle.id] = nil; operationTasks[bottle.id] = nil
                stoppingBottles.remove(bottle.id); refreshLog()
            }
            do { _ = try await runGraphicsProbe(in: bottle) }
            catch { graphicsReports[bottle.id] = nil; if !(error is CancellationError) { show(error) } }
        }
    }

    func chooseGameExecutable(startingAt bottle: Bottle?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Виберіть виконуваний файл гри")
        panel.message = L10n.text("Додайте встановлену гру (.exe). Інсталятор запускається окремо з розділу «Середовища».")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let bottle, let store { panel.directoryURL = store.prefixURL(for: bottle).appendingPathComponent("drive_c") }
        return panel.runModal() == .OK ? panel.url : nil
    }
    func chooseWorkingDirectory(startingAt path: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Виберіть робочу папку гри")
        panel.message = L10n.text("Папка, у якій гра шукатиме свої дані. Зазвичай це папка поруч із .exe.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if path.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
        return panel.runModal() == .OK ? panel.url : nil
    }
    func saveGame(id: UUID? = nil, name: String, bottleID: UUID, path: String, arguments: [String], workingDirectory: String,
                  launchMethod: GameLaunchMethod, steamAppID: String, crossOver: CrossOverGame?,
                  graphicsProfile: GameGraphicsProfile = .automatic, graphicsExecutablePath: String = "", enableMetalFX: Bool = false) {
        var game: Game
        if let id {
            guard let existing = library.games.first(where: { $0.id == id }) else {
                show(PorticoError.invalidInput(L10n.text("Цю гру вже вилучено з бібліотеки."))); return
            }
            game = existing
        } else {
            game = Game(name: name, bottleID: bottleID, executablePath: path)
        }
        let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : workingDirectory
        let routeChanged = id == nil || game.effectiveLaunchMethod != launchMethod || game.bottleID != bottleID
            || (launchMethod == .steam && (game.steamAppID ?? "") != steamAppID)
            || (launchMethod == .executable && (game.executablePath != path || game.arguments != arguments || game.workingDirectory != directory))
            || (launchMethod == .crossOver && game.crossOverLauncher != crossOver)
        do {
            let graphicsChanged = game.effectiveGraphicsProfile != graphicsProfile || (game.graphicsExecutablePath ?? "") != graphicsExecutablePath
                || game.effectiveMetalFXEnabled != enableMetalFX
            if graphicsChanged && (runningGames[game.id] != nil || preparingGames.contains(game.id)) { throw PorticoError.busy }
            if routeChanged {
                guard runningGames[game.id] == nil, !crossOverLaunchRequests.contains(game.id) else { throw PorticoError.busy }
                let bottle = library.bottles.first { $0.id == bottleID }
                game = try game.selectingLaunch(method: launchMethod, bottle: bottle,
                    prefix: bottle.flatMap { store?.prefixURL(for: $0) }, appID: steamAppID,
                    executable: path, arguments: arguments, directory: directory, crossOver: crossOver)
            }
            game.graphicsProfile = graphicsProfile
            game.enableMetalFX = enableMetalFX
            game.graphicsExecutablePath = graphicsExecutablePath.isEmpty ? nil : graphicsExecutablePath
            if launchMethod != .crossOver, graphicsProfile == .directX9,
               let bottle = library.bottles.first(where: { $0.id == bottleID }), let store {
                guard let target = try GameGraphics.targetExecutable(game: game, prefix: store.prefixURL(for: bottle)) else {
                    throw PorticoError.invalidInput(L10n.text("Виберіть .exe гри в налаштуваннях графіки та збережіть конфігурацію."))
                }
                if launchMethod == .steam { game.graphicsExecutablePath = target.path }
            }
            if routeChanged || graphicsChanged { preparedGames.remove(game.id) }
        }
        catch { show(error); return }
        game.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = library
        if let index = next.games.firstIndex(where: { $0.id == game.id }) { next.games[index] = game }
        else { next.games.append(game) }
        if commit(next) {
            sheet = nil
            if section != .setup { section = .library }
            if id == nil { filter = .all; search = "" }
        }
    }
    func toggleFavorite(_ game: Game) {
        var next = library
        if let i = next.games.firstIndex(where: { $0.id == game.id }) { next.games[i].isFavorite.toggle(); commit(next) }
    }
    func removeGame(_ game: Game) {
        sheet = .removeGame(.game(game))
    }
    func launch(_ game: Game) {
        sheet = .launchGuide(game)
    }

    func editGameFromGuide(_ game: Game) {
        if !library.games.contains(where: { $0.id == game.id }) {
            var next = library; next.games.append(game)
            guard commit(next) else { return }
        }
        sheet = .editGame(game.id)
    }

    func requestSteamLaunch(_ installed: SteamInstalledGame, in bottle: Bottle) {
        if let game = library.games.first(where: { $0.bottleID == bottle.id && $0.steamAppID == installed.id }) {
            launch(game)
        } else if let store, let client = SteamSupport.executable(in: store.prefixURL(for: bottle)) {
            launch(Game(name: installed.name, bottleID: bottle.id, executablePath: client.path,
                        workingDirectory: installed.installDirectory.path, steamAppID: installed.id))
        }
    }

    func prepareGame(_ game: Game, installLegacyDirectX: Bool = false) {
        guard game.effectiveLaunchMethod != .crossOver,
              let bottle = bottle(for: game), let store, canPrepareGame(in: bottle),
              !preparingGames.contains(game.id) else { return }
        let existingSteam = steamSessions.contains(bottle.id)
        preparingGames.insert(game.id)
        preparedGames.remove(game.id)
        gamePreparationErrors[game.id] = nil
        gamePreparationProgress[game.id] = nil
        steamCommands.insert(bottle.id)
        if !existingSteam { operations[bottle.id] = "Підготовка компонентів гри…" }
        let task = Task {
            defer {
                preparingGames.remove(game.id)
                steamCommands.remove(bottle.id)
                if existingSteam { steamCommandTasks[bottle.id] = nil }
                else { operations[bottle.id] = nil; operationTasks[bottle.id] = nil }
                stoppingBottles.remove(bottle.id)
                gamePreparationProgress[game.id] = nil
                refreshLog()
            }
            do {
                var archive: URL?
                if installLegacyDirectX {
                    archive = try await DirectXLegacyRuntime.download(using: runtimeInstaller, root: store.rootURL) { [weak self] progress in
                        Task { @MainActor in self?.gamePreparationProgress[game.id] = progress }
                    }
                    gamePreparationProgress[game.id] = InstallProgress(stage: "directx-installer")
                }
                try await engine.prepareGameGraphics(game: game, bottle: bottle, prefix: store.prefixURL(for: bottle),
                    logURL: store.logURL(for: bottle).deletingPathExtension().appendingPathExtension("prepare.log"),
                    verbose: library.settings.verboseLogging, legacyArchive: archive)
                preparedGames.insert(game.id)
            } catch {
                gamePreparationErrors[game.id] = error.localizedDescription
            }
        }
        if existingSteam { steamCommandTasks[bottle.id] = task }
        else { operationTasks[bottle.id] = task }
    }

    /// Only the guide's explicit Launch button dispatches a game.
    func launchPrepared(_ game: Game) {
        guard !preparingGames.contains(game.id), canLaunch(game) else { return }
        do {
            try game.validateLaunchConfiguration()
            if game.effectiveLaunchMethod != .crossOver, let bottle = bottle(for: game), let store {
                let status = try GameGraphics.inspect(game: game, prefix: store.prefixURL(for: bottle))
                guard status.configured || preparedGames.contains(game.id) else {
                    throw PorticoError.invalidInput(L10n.text("Спочатку застосуйте вибрану конфігурацію графіки."))
                }
            }
            if game.effectiveLaunchMethod == .steam, let bottle = bottle(for: game), let store {
                guard try SteamSupport.installedGames(in: store.prefixURL(for: bottle)).contains(where: { $0.id == game.steamAppID }) else {
                    throw PorticoError.invalidInput(L10n.text("Цю гру не встановлено у вибраному середовищі Steam. Установіть її у клієнті або виберіть інше середовище."))
                }
                if !library.games.contains(where: { $0.id == game.id }) {
                    var next = library; next.games.append(game)
                    guard commit(next) else { return }
                }
            }
        } catch { show(error); return }
        sheet = nil
        if game.effectiveLaunchMethod == .crossOver {
            guard let launcher = game.crossOverLauncher else { return }
            launchCrossOverGame(launcher, libraryGameID: library.games.contains(where: { $0.id == game.id }) ? game.id : nil)
            return
        }
        if game.effectiveLaunchMethod == .steam, let appID = game.steamAppID, let bottle = bottle(for: game) {
            steam(.run(appID: appID), in: bottle, gameID: game.id)
            return
        }
        guard let bottle = bottle(for: game), let store, !isBusy(bottle), bottle.status == .ready else { return }
        operations[bottle.id] = "Запущено: \(game.name)"
        runningGames[game.id] = bottle.id
        logBottleID = bottle.id
        operationTasks[bottle.id] = Task {
            do {
                _ = try await engine.launch(game: game, bottle: bottle, prefix: store.prefixURL(for: bottle), logURL: store.logURL(for: bottle), verbose: library.settings.verboseLogging, showFPS: library.settings.showFPS)
                var next = library
                if let i = next.games.firstIndex(where: { $0.id == game.id }) { next.games[i].lastPlayedAt = Date(); commit(next) }
            } catch { if !stoppingBottles.contains(bottle.id) { show(error) } }
            operations[bottle.id] = nil; operationTasks[bottle.id] = nil; runningGames[game.id] = nil; stoppingBottles.remove(bottle.id); refreshLog()
        }
    }
    func stop(_ bottle: Bottle) {
        guard let store, operations[bottle.id] != nil, !stopCommands.contains(bottle.id) else { return }
        stoppingBottles.insert(bottle.id)
        if steamInstallerDownloads.contains(bottle.id) {
            operationTasks[bottle.id]?.cancel()
            return
        }
        stopCommands.insert(bottle.id)
        Task {
            defer { stopCommands.remove(bottle.id) }
            do {
                try await engine.stop(bottle: bottle, prefix: store.prefixURL(for: bottle))
                steamCommandTasks[bottle.id]?.cancel()
                operationTasks[bottle.id]?.cancel()
            }
            catch { stoppingBottles.remove(bottle.id); show(error) }
        }
    }

    func stopAllForExit() async -> Bool {
        if let setupTask {
            setupTask.cancel()
            await setupTask.value
        }
        guard let store else { return operations.isEmpty }
        let active = library.bottles.filter { operations[$0.id] != nil }
        for bottle in active {
            stoppingBottles.insert(bottle.id)
            if steamInstallerDownloads.contains(bottle.id) {
                operationTasks[bottle.id]?.cancel()
                continue
            }
            do {
                try await engine.stop(bottle: bottle, prefix: store.prefixURL(for: bottle))
                steamCommandTasks[bottle.id]?.cancel()
                operationTasks[bottle.id]?.cancel()
            }
            catch { stoppingBottles.remove(bottle.id); show(error); return false }
        }
        for _ in 0..<100 {
            if operations.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        notice = Notice(title: L10n.text("Середовище ще працює"), message: L10n.text("Wine ще не підтвердив завершення процесів. Перевірте журнал і повторіть зупинку."))
        for bottle in active { stoppingBottles.remove(bottle.id) }
        return false
    }
    func install(in bottle: Bottle) {
        guard let store, bottle.status == .ready, !isBusy(bottle) else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Виберіть інсталятор для Windows")
        panel.message = L10n.text("Підтримуються .exe та .msi. Програму буде запущено в середовищі «\(bottle.name)».")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        guard ["exe", "msi"].contains(file.pathExtension.lowercased()) else {
            show(PorticoError.invalidInput(L10n.text("Потрібен інсталятор .exe або .msi."))); return
        }
        operations[bottle.id] = "Встановлення: \(file.lastPathComponent)"
        logBottleID = bottle.id
        operationTasks[bottle.id] = Task {
            do {
                _ = try await engine.install(installer: file, bottle: bottle, prefix: store.prefixURL(for: bottle), logURL: store.logURL(for: bottle), verbose: library.settings.verboseLogging)
                notice = Notice(title: L10n.text("Інсталятор завершив роботу"), message: L10n.text("Якщо встановлення пройшло успішно, натисніть «Додати гру» й виберіть її .exe всередині середовища «\(bottle.name)»."))
            } catch { if !stoppingBottles.contains(bottle.id) { show(error) } }
            operations[bottle.id] = nil; operationTasks[bottle.id] = nil; stoppingBottles.remove(bottle.id); refreshLog()
        }
    }
    func configure(_ bottle: Bottle) {
        guard let store, bottle.status == .ready, !isBusy(bottle) else { return }
        operations[bottle.id] = "Відкрито налаштування Wine"
        logBottleID = bottle.id
        operationTasks[bottle.id] = Task {
            do { _ = try await engine.configure(bottle: bottle, prefix: store.prefixURL(for: bottle), logURL: store.logURL(for: bottle), verbose: library.settings.verboseLogging) }
            catch { if !stoppingBottles.contains(bottle.id) { show(error) } }
            operations[bottle.id] = nil; operationTasks[bottle.id] = nil; stoppingBottles.remove(bottle.id); refreshLog()
        }
    }
    func revealBottle(_ bottle: Bottle) {
        guard let store else { return }
        let url = store.prefixURL(for: bottle)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }
    func showLog(_ bottle: Bottle) { logBottleID = bottle.id; section = .logs; refreshLog() }
    func refreshLog() {
        guard let store, let bottle = library.bottles.first(where: { $0.id == logBottleID }) ?? library.bottles.first else {
            logText = ""; return
        }
        if logBottleID == nil { logBottleID = bottle.id }
        let url = store.logURL(for: bottle)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let count = try handle.seekToEnd()
            try handle.seek(toOffset: count > 100_000 ? count - 100_000 : 0)
            logText = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch { logText = L10n.text("Журнал цього середовища поки порожній.") }
    }
    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Portico-diagnostics.txt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try logText.write(to: url, atomically: true, encoding: .utf8) } catch { show(error) }
        }
    }
    func openURL(_ value: String) { if let url = URL(string: value) { NSWorkspace.shared.open(url) } }
}

@MainActor
extension AppModel {
    func canPrepareGame(in bottle: Bottle) -> Bool {
        guard bottle.status == .ready, store != nil,
              !steamStarting.contains(bottle.id),
              !stoppingBottles.contains(bottle.id), !steamCommands.contains(bottle.id),
              !isBusy(bottle) || steamSessions.contains(bottle.id) else { return false }
        return true
    }

    func canUseSteam(in bottle: Bottle) -> Bool {
        guard canPrepareGame(in: bottle), let store else { return false }
        return SteamSupport.executable(in: store.prefixURL(for: bottle)) != nil
    }

    func canLaunch(_ game: Game) -> Bool {
        if game.effectiveLaunchMethod == .crossOver {
            guard !crossOverLaunchRequests.contains(game.id), let launcher = game.crossOverLauncher else { return false }
            return (try? CrossOverSupport.launchURL(for: launcher)) != nil
        }
        guard let bottle = bottle(for: game), bottle.status == .ready else { return false }
        return game.effectiveLaunchMethod == .executable ? !isBusy(bottle) : game.steamAppID != nil && canUseSteam(in: bottle)
    }

    func refreshSteam(in bottle: Bottle) {
        guard let store else { return }
        let prefix = store.prefixURL(for: bottle)
        steamClients[bottle.id] = SteamSupport.executable(in: prefix)
        do {
            steamInstalledGames[bottle.id] = try SteamSupport.installedGames(in: prefix)
            steamScanErrors[bottle.id] = nil
        } catch {
            steamInstalledGames[bottle.id] = []
            steamScanErrors[bottle.id] = error.localizedDescription
        }
    }

    func installSteam(in bottle: Bottle) {
        guard !isUISimulation else {
            show(PorticoError.invalidInput(L10n.text("Це тестова копія Portico із симулятором Wine. Вона не запускає інсталятори для Windows. Відкрийте звичайний застосунок Portico й підключіть робочий Wine.")))
            return
        }
        guard !DistributionPolicy.isAppStore, let store, bottle.status == .ready, !isBusy(bottle) else { return }
        refreshSteam(in: bottle)
        guard steamClients[bottle.id] == nil else { return }
        operations[bottle.id] = "Завантажуємо інсталятор Steam для Windows…"
        steamInstallerDownloads.insert(bottle.id)
        steamMessages[bottle.id] = nil
        logBottleID = bottle.id
        operationTasks[bottle.id] = Task {
            var installer: URL?
            defer {
                if let installer { SteamSupport.cleanupInstaller(at: installer) }
                steamInstallerDownloads.remove(bottle.id)
                operations[bottle.id] = nil
                operationTasks[bottle.id] = nil
                stoppingBottles.remove(bottle.id)
                refreshSteam(in: bottle)
                refreshLog()
            }
            do {
                installer = try await steamSupport.downloadInstaller()
                try Task.checkCancellation()
                steamInstallerDownloads.remove(bottle.id)
                operations[bottle.id] = "Інсталятор Steam відкрито — завершіть встановлення в його вікні"
                guard let installer else { return }
                _ = try await engine.install(installer: installer, bottle: bottle,
                    prefix: store.prefixURL(for: bottle), logURL: store.logURL(for: bottle),
                    verbose: library.settings.verboseLogging)
                refreshSteam(in: bottle)
                steamMessages[bottle.id] = steamClients[bottle.id] == nil
                    ? "Інсталятор закрився, але Steam не знайдено. Повторіть встановлення й залиште стандартну папку призначення."
                    : "Steam встановлено. Відкрийте клієнт і ввійдіть у свій обліковий запис."
            } catch {
                if stoppingBottles.contains(bottle.id) || error is CancellationError {
                    steamMessages[bottle.id] = "Встановлення зупинено. Якщо Steam уже встановлено, його можна відкрити знову."
                } else {
                    steamMessages[bottle.id] = LocalizedMessage(verbatim: error.localizedDescription)
                    show(error)
                }
            }
        }
    }

    func steam(_ action: SteamAction, in bottle: Bottle, gameID: UUID? = nil) {
        guard let store, canUseSteam(in: bottle) else { return }
        do { _ = try action.uri } catch { show(error); return }
        let existingSession = steamSessions.contains(bottle.id)
        let requestedGame = gameID.flatMap { id in library.games.first { $0.id == id } } ?? {
            if case .run(let appID) = action {
                return library.games.first { $0.bottleID == bottle.id && $0.steamAppID == appID }
            }
            return nil
        }()
        let metalFX = requestedGame.map {
            $0.effectiveMetalFXEnabled && MetalFX.isSupported(game: $0, bottle: bottle)
        }
        let requestedAt = Date()
        steamMessages[bottle.id] = nil
        logBottleID = bottle.id
        if existingSession {
            steamCommands.insert(bottle.id)
            steamCommandTasks[bottle.id] = Task {
                defer {
                    steamCommands.remove(bottle.id)
                    steamCommandTasks[bottle.id] = nil
                    refreshSteam(in: bottle)
                    refreshLog()
                }
                do {
                    _ = try await engine.steam(action: action, bottle: bottle,
                        prefix: store.prefixURL(for: bottle), logURL: store.logURL(for: bottle),
                        verbose: library.settings.verboseLogging, existingSessionOnly: true, showFPS: library.settings.showFPS,
                        enableMetalFX: metalFX)
                    recordSteamLaunch(gameID: gameID, at: requestedAt)
                } catch {
                    if !stoppingBottles.contains(bottle.id), !(error is CancellationError) { show(error) }
                }
            }
        } else {
            steamSessions.insert(bottle.id)
            steamStarting.insert(bottle.id)
            operations[bottle.id] = "Steam запускається — очікуємо готовності клієнта"
            operationTasks[bottle.id] = Task {
                let readiness = Task {
                    while !Task.isCancelled {
                        if await engine.isSteamReady(prefix: store.prefixURL(for: bottle)) {
                            steamStarting.remove(bottle.id)
                            operations[bottle.id] = "Steam працює · ігри та завантаження доступні в клієнті"
                            return
                        }
                        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    }
                }
                defer {
                    readiness.cancel()
                    steamStarting.remove(bottle.id)
                    steamCommandTasks[bottle.id]?.cancel()
                    steamSessions.remove(bottle.id)
                    operations[bottle.id] = nil
                    operationTasks[bottle.id] = nil
                    stoppingBottles.remove(bottle.id)
                    refreshSteam(in: bottle)
                    refreshLog()
                }
                do {
                    _ = try await engine.steam(action: action, bottle: bottle,
                        prefix: store.prefixURL(for: bottle), logURL: store.logURL(for: bottle),
                        verbose: library.settings.verboseLogging, showFPS: library.settings.showFPS, enableMetalFX: metalFX)
                    recordSteamLaunch(gameID: gameID, at: requestedAt)
                } catch {
                    if !stoppingBottles.contains(bottle.id), !(error is CancellationError) { show(error) }
                }
            }
        }
    }

    private func recordSteamLaunch(gameID: UUID?, at date: Date) {
        guard let gameID, let index = library.games.firstIndex(where: { $0.id == gameID }) else { return }
        var next = library
        if (next.games[index].lastPlayedAt ?? .distantPast) < date {
            next.games[index].lastPlayedAt = date
            commit(next)
        }
    }

    func importSteamGames(from bottle: Bottle) {
        refreshSteam(in: bottle)
        guard let client = steamClients[bottle.id], steamScanErrors[bottle.id] == nil else { return }
        let installed = steamInstalledGames[bottle.id] ?? []
        var next = library
        var added = 0
        for game in installed {
            if let index = next.games.firstIndex(where: { $0.bottleID == bottle.id && $0.steamAppID == game.id }) {
                if next.games[index].effectiveLaunchMethod == .steam {
                    next.games[index].executablePath = client.path
                    next.games[index].workingDirectory = game.installDirectory.path
                }
            } else {
                next.games.append(Game(name: game.name, bottleID: bottle.id, executablePath: client.path,
                    workingDirectory: game.installDirectory.path, steamAppID: game.id))
                added += 1
            }
        }
        guard commit(next) else { return }
        steamMessages[bottle.id] = installed.isEmpty
            ? "Встановлених ігор поки немає. Дочекайтеся завершення завантаження в Steam і оновіть список."
            : added == 0 ? "Усі знайдені ігри вже є в бібліотеці Portico." : "Додано ігор до бібліотеки Portico: \(added)."
    }
}
