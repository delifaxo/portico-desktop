import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PorticoCore

private struct GameArgumentDraft: Identifiable {
    let id = UUID()
    var value: String
}

struct GameEditorSheet: View {
    @ObservedObject var model: AppModel
    private let original: Game?
    @State private var name: String
    @State private var bottleID: UUID?
    @State private var method: GameLaunchMethod
    @State private var appID: String
    @State private var path: String
    @State private var workingDirectory: String
    @State private var arguments: [GameArgumentDraft]
    @State private var showLaunchSettings = false
    @State private var crossOver: CrossOverGame?
    @State private var crossOverCandidates: [CrossOverGame] = []
    @State private var runtimeLabel = ""
    @State private var directX9Status: GameGraphics.Status?
    @State private var graphicsProfile: GameGraphicsProfile
    @State private var graphicsExecutablePath: String
    @State private var enableMetalFX: Bool
    @State private var graphicsError: String?

    init(model: AppModel, game: Game? = nil, showLaunchSettings: Bool = false) {
        self.model = model
        original = game
        _showLaunchSettings = State(initialValue: showLaunchSettings)
        _name = State(initialValue: game?.name ?? "")
        _bottleID = State(initialValue: game?.bottleID ?? model.newGameBottleID.flatMap { id in model.readyBottles.first { $0.id == id }?.id } ?? model.readyBottles.first?.id)
        _method = State(initialValue: game?.effectiveLaunchMethod ?? .executable)
        _appID = State(initialValue: game?.steamAppID ?? "")
        _path = State(initialValue: game?.executablePath ?? "")
        _workingDirectory = State(initialValue: game?.workingDirectory ?? "")
        _arguments = State(initialValue: (game?.arguments ?? []).map { GameArgumentDraft(value: $0) })
        _crossOver = State(initialValue: game?.crossOverLauncher)
        _graphicsProfile = State(initialValue: game?.effectiveGraphicsProfile ?? .automatic)
        _graphicsExecutablePath = State(initialValue: game?.graphicsExecutablePath ?? "")
        _enableMetalFX = State(initialValue: game?.effectiveMetalFXEnabled ?? false)
    }

    private var selectedBottle: Bottle? { model.library.bottles.first { $0.id == bottleID } }
    private var installedGames: [SteamInstalledGame] { bottleID.flatMap { model.steamInstalledGames[$0] } ?? [] }
    private var selectedSteamGame: SteamInstalledGame? {
        let id = try? SteamAction.validatedAppID(appID.trimmingCharacters(in: .whitespacesAndNewlines))
        return installedGames.first { $0.id == id }
    }
    private var hasLaunchChanges: Bool {
        guard let original else { return true }
        if original.effectiveLaunchMethod != method || original.bottleID != bottleID { return true }
        if original.effectiveGraphicsProfile != graphicsProfile || (original.graphicsExecutablePath ?? "") != graphicsExecutablePath { return true }
        if original.effectiveMetalFXEnabled != enableMetalFX { return true }
        switch method {
        case .steam: return (original.steamAppID ?? "") != appID
        case .executable:
            return original.executablePath != path || (original.workingDirectory ?? "") != workingDirectory
                || original.arguments != arguments.map(\.value)
        case .crossOver: return original.crossOverLauncher != crossOver
        }
    }
    private var running: Bool { original.map { model.runningGames[$0.id] != nil } ?? false }
    private var preparing: Bool { original.map { model.preparingGames.contains($0.id) } ?? false }
    private var graphicsDraft: Game {
        var game = original ?? Game(name: name, bottleID: bottleID ?? UUID(), executablePath: path)
        game.bottleID = bottleID ?? game.bottleID
        game.launchMethod = method; game.executablePath = path; game.steamAppID = appID
        game.graphicsProfile = graphicsProfile
        game.enableMetalFX = enableMetalFX
        game.graphicsExecutablePath = graphicsExecutablePath.isEmpty ? nil : graphicsExecutablePath
        return game
    }
    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, bottleID != nil else { return false }
        if !hasLaunchChanges { return true }
        guard !running else { return false }
        switch method {
        case .crossOver: return !DistributionPolicy.isAppStore && crossOver != nil
        case .steam:
            return selectedBottle?.status == .ready && bottleID.flatMap { model.steamClients[$0] } != nil && selectedSteamGame != nil
        case .executable:
            return selectedBottle?.status == .ready && !path.isEmpty
                && URL(fileURLWithPath: path).pathExtension.lowercased() == "exe"
                && URL(fileURLWithPath: path).lastPathComponent.lowercased() != "steam.exe"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 13) {
                Image(systemName: "gearshape.fill").font(.system(size: 23)).foregroundStyle(Palette.mint)
                    .frame(width: 48, height: 48).background(Palette.elevated, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(original == nil ? L10n.text("Додати гру") : L10n.text("Налаштування гри"))
                        .font(.system(size: 23, weight: .semibold))
                    Text(L10n.text("Виберіть спосіб запуску гри. Зміни діятимуть під час наступного запуску."))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameField
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L10n.text("Спосіб запуску")).font(.system(size: 12, weight: .semibold))
                        Picker(L10n.text("Спосіб запуску"), selection: $method) {
                            Text("Steam").tag(GameLaunchMethod.steam)
                            Text(L10n.text("Напряму через .exe")).tag(GameLaunchMethod.executable)
                            if original != nil && (!DistributionPolicy.isAppStore || method == .crossOver) {
                                Text("CrossOver").tag(GameLaunchMethod.crossOver)
                            }
                        }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("game-launch-method")
                        if method == .crossOver {
                            crossOverFields
                        } else {
                            environmentField
                            directX9Configuration
                            if let selectedBottle, MetalFX.isSupported(game: graphicsDraft, bottle: selectedBottle) {
                                metalFXConfiguration
                            }
                            Divider().overlay(Palette.muted.opacity(0.15))
                            if method == .steam { steamFields }
                            else {
                                executableField
                                if original?.steamAppID != nil {
                                    Text(L10n.text("Деякі ігри потребують запуску зі Steam навіть після вибору файлу .exe."))
                                        .font(.system(size: 11)).foregroundStyle(Palette.amber)
                                }
                                DisclosureGroup(L10n.text("Параметри запуску"), isExpanded: $showLaunchSettings) {
                                    launchFields.padding(.top, 10)
                                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                        }
                    }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                        .disabled(running || preparing)
                    if running {
                        Text(L10n.text("Завершіть гру, щоб змінити спосіб її запуску."))
                            .font(.system(size: 11)).foregroundStyle(Palette.amber)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }.frame(maxHeight: 490)
            HStack {
                Spacer()
                Button(L10n.text("Скасувати")) { model.sheet = nil }
                    .buttonStyle(PorticoButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("game-editor-cancel").disabled(preparing)
                Button(original == nil ? L10n.text("Додати гру") : L10n.text("Зберегти")) {
                    guard let bottleID else { return }
                    model.saveGame(id: original?.id, name: name, bottleID: bottleID, path: path,
                        arguments: arguments.map(\.value), workingDirectory: workingDirectory,
                        launchMethod: method, steamAppID: appID, crossOver: crossOver,
                        graphicsProfile: graphicsProfile, graphicsExecutablePath: graphicsExecutablePath,
                        enableMetalFX: enableMetalFX)
                }.buttonStyle(PorticoButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(!canSave || preparing).accessibilityIdentifier("game-editor-save")
            }
        }.padding(28).frame(width: 630).background(Palette.sidebar)
            .interactiveDismissDisabled(preparing)
            .task(id: "\(bottleID?.uuidString ?? "none")-\(method.rawValue)-\(appID)-\(path)-\(graphicsProfile.rawValue)-\(graphicsExecutablePath)") {
                refreshDestination(); refreshDirectX9()
            }
            .onChange(of: preparing) { _, busy in if !busy { refreshDirectX9() } }
            .onAppear { crossOverCandidates = CrossOverSupport.discoverGames() }
            .onChange(of: method) { _, value in
                if value == .executable, URL(fileURLWithPath: path).lastPathComponent.lowercased() == "steam.exe" { path = "" }
            }
            .onChange(of: bottleID) { _, _ in graphicsExecutablePath = "" }
            .onChange(of: appID) { _, _ in graphicsExecutablePath = "" }
    }

    private var metalFXConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("DLSS → MetalFX", isOn: $enableMetalFX)
                .toggleStyle(.switch).tint(Palette.mint)
                .accessibilityIdentifier("game-metalfx-toggle")
            Text(L10n.text("Використовує MetalFX у сумісних іграх із DLSS. Після ввімкнення виберіть DLSS у графічних налаштуваннях гри. Підтримка залежить від гри та версії GPTK."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Закрийте гру та Steam у цьому середовищі, потім запустіть гру з Portico, щоб застосувати зміну."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var directX9Configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("Графіка гри"), systemImage: "display").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.mint)
            Picker(L10n.text("Графічний профіль"), selection: $graphicsProfile) {
                ForEach(GameGraphicsProfile.allCases) { profile in Text(profile.label).tag(profile) }
            }.labelsHidden().accessibilityIdentifier("game-graphics-profile")
            Text(graphicsProfile == .directX9
                 ? L10n.text("WineD3D і бібліотеки D3DX9 для ігор, що використовують DirectX 9.")
                 : L10n.text("Гра використовує графіку вибраного середовища. Для DirectX 11/12 виберіть відповідне оточення D3DMetal."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if graphicsProfile == .directX9 {
                if method == .steam {
                    Text(L10n.text("Файл гри для налаштування графіки (.exe)")).font(.system(size: 11, weight: .medium))
                    HStack {
                        TextField(directX9Status?.executable?.path ?? L10n.text("Виберіть .exe самої гри"), text: $graphicsExecutablePath)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("game-graphics-executable")
                        Button(L10n.text("Вибрати…")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                            panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
                            panel.directoryURL = selectedSteamGame?.installDirectory
                            if panel.runModal() == .OK, let url = panel.url { graphicsExecutablePath = url.path }
                        }.buttonStyle(PorticoButtonStyle()).accessibilityIdentifier("game-graphics-browse")
                    }
                    Text(L10n.text("Steam залишається способом запуску. Цей файл визначає, до якої гри застосовуються налаштування графіки."))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                } else {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                }
            }
            if graphicsProfile == .directX9 || directX9Status?.needsRestore == true {
                let configured = !hasLaunchChanges && (directX9Status?.configured == true
                    || original.map { model.preparedGames.contains($0.id) } == true)
                Label(configured ? L10n.text("Конфігурацію застосовано") : L10n.text("Потрібно застосувати конфігурацію"),
                      systemImage: configured ? "checkmark.circle.fill" : "wrench.and.screwdriver")
                    .font(.system(size: 11)).foregroundStyle(configured ? Palette.mint : Palette.amber)
                Button {
                    if let original { model.prepareGame(original) }
                } label: {
                    Label(preparing ? L10n.text("Підготовка компонентів гри…") : L10n.text("Застосувати конфігурацію"),
                          systemImage: "wrench.and.screwdriver")
                }.buttonStyle(PorticoButtonStyle())
                    .disabled(original == nil || hasLaunchChanges || preparing || DistributionPolicy.isAppStore
                        || selectedBottle.map { !model.canPrepareGame(in: $0) } != false)
                    .accessibilityIdentifier("game-directx9-prepare")
                Text(hasLaunchChanges || original == nil
                     ? L10n.text("Спочатку збережіть гру та вибраний спосіб запуску.")
                     : L10n.text("Закрийте гру перед налаштуванням графіки. Steam можна залишити відкритим."))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                if graphicsProfile == .directX9 {
                    Button(L10n.text("Завантажити та встановити компоненти DirectX…")) {
                        if let original { model.prepareGame(original, installLegacyDirectX: true) }
                    }.buttonStyle(PorticoButtonStyle())
                        .disabled(original == nil || hasLaunchChanges || preparing || DistributionPolicy.isAppStore
                            || selectedBottle.map { !model.canPrepareGame(in: $0) } != false)
                        .accessibilityIdentifier("game-directx9-download")
                    Text(L10n.text("Microsoft · June 2010 · 100 МБ. У разі помилок D3DX9 або D3DCompiler завершіть встановлення у вікні інсталятора."))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                if let original, let progress = model.gamePreparationProgress[original.id] {
                    GamePreparationProgress(progress: progress)
                }
                if let original, let error = model.gamePreparationErrors[original.id] {
                    Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber)
                }
            }
            if let graphicsError { Text(graphicsError).font(.system(size: 11)).foregroundStyle(Palette.amber) }
        }
    }

    private func refreshDirectX9() {
        graphicsError = nil; directX9Status = nil
        guard method != .crossOver, let selectedBottle, let store = model.store else { return }
        do { directX9Status = try GameGraphics.inspect(game: graphicsDraft, prefix: store.prefixURL(for: selectedBottle)) }
        catch { if graphicsProfile == .directX9 { graphicsError = error.localizedDescription } }
    }

    private var environmentField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Середовище та рушій")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
            Picker(L10n.text("Середовище"), selection: $bottleID) {
                if let bottleID, !model.readyBottles.contains(where: { $0.id == bottleID }) {
                    Text(L10n.text("Поточне середовище не готове")).tag(Optional(bottleID))
                }
                ForEach(model.readyBottles) { bottle in Text(bottle.name).tag(Optional(bottle.id)) }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("game-launch-environment")
            if selectedBottle != nil {
                Label(runtimeLabel, systemImage: "cpu").font(.system(size: 11)).foregroundStyle(Palette.mint)
                Text(L10n.text("Кожне середовище використовує власний рушій. Виберіть інше середовище, щоб змінити рушій гри."))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.text("Спочатку створіть середовище й дочекайтеся завершення підготовки."))
                    .font(.system(size: 11)).foregroundStyle(Palette.amber)
            }
        }
    }

    private var steamFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Гра у Steam")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
            if !installedGames.isEmpty {
                Picker(L10n.text("Гра у Steam"), selection: $appID) {
                    if !installedGames.contains(where: { $0.id == appID }) {
                        Text(appID.isEmpty ? L10n.text("Виберіть гру") : "App ID: \(appID)").tag(appID)
                    }
                    ForEach(installedGames) { game in Text(game.name).tag(game.id) }
                }.labelsHidden().accessibilityIdentifier("game-steam-installed")
            }
            HStack {
                Text("App ID").font(.system(size: 11)).foregroundStyle(Palette.muted)
                TextField("1771300", text: $appID).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("game-steam-app-id")
                Button(L10n.text("Оновити")) { refreshDestination() }.buttonStyle(PorticoButtonStyle())
            }
            if let selectedSteamGame {
                Label(L10n.text("Гру встановлено в цьому середовищі"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Palette.mint)
                Text(selectedSteamGame.installDirectory.path).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            } else {
                Text(bottleID.flatMap { model.steamClients[$0] } == nil
                     ? L10n.text("У вибраному середовищі не встановлено Steam.")
                     : L10n.text("Цю гру не встановлено у вибраному середовищі Steam. Установіть її у клієнті або виберіть інше середовище."))
                    .font(.system(size: 11)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.text("Steam запустить гру за App ID. Параметри запуску задаються у властивостях гри у Steam."))
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }

    private var crossOverFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Ярлик гри CrossOver")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
            Picker(L10n.text("Ярлик гри CrossOver"), selection: Binding(
                get: { crossOver?.launcherPath ?? "" },
                set: { value in crossOver = crossOverCandidates.first { $0.launcherPath == value } }
            )) {
                Text(L10n.text("Виберіть ярлик")).tag("")
                if let crossOver, !crossOverCandidates.contains(where: { $0.launcherPath == crossOver.launcherPath }) {
                    Text(crossOver.name).tag(crossOver.launcherPath)
                }
                ForEach(crossOverCandidates) { game in Text("\(game.name) · \(game.bottleName)").tag(game.launcherPath) }
            }.labelsHidden().accessibilityIdentifier("game-crossover-launcher")
            Button(L10n.text("Вибрати ярлик…")) {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.applicationBundle]
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = CrossOverSupport.defaultLaunchersURL
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do { crossOver = try CrossOverSupport.game(at: url) } catch { model.show(error) }
            }.buttonStyle(PorticoButtonStyle())
            if let crossOver {
                Label("CrossOver · \(crossOver.bottleName)", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11)).foregroundStyle(Palette.mint)
            }
            Text(L10n.text("Відкриється вибраний ярлик установленого CrossOver. Гра використає його середовище та налаштування."))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var executableField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Файл гри (.exe)")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
            HStack(spacing: 8) {
                TextField(L10n.text("Шлях до гри"), text: $path).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("game-executable-path")
                Button(L10n.text("Вибрати…")) {
                    if let url = model.chooseGameExecutable(startingAt: selectedBottle) {
                        path = url.path
                        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                    }
                }.buttonStyle(PorticoButtonStyle())
            }
            Text(L10n.text("Виберіть середовище, де встановлена гра. Зміна середовища не переносить її файли та збереження."))
                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Назва в бібліотеці")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
            TextField(L10n.text("Назва гри"), text: $name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("game-editor-name")
        }
    }

    private func refreshDestination() {
        guard let bottle = selectedBottle else { runtimeLabel = ""; return }
        if method == .steam { model.refreshSteam(in: bottle) }
        runtimeLabel = model.runtimeDescription(for: bottle)
    }

    private var launchFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Робоча папка")).font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
                TextField(L10n.text("За замовчуванням — папка з .exe"), text: $workingDirectory).textFieldStyle(.roundedBorder)
                Button(L10n.text("Вибрати…")) {
                    let start = workingDirectory.isEmpty ? URL(fileURLWithPath: path).deletingLastPathComponent().path : workingDirectory
                    if let url = model.chooseWorkingDirectory(startingAt: start) { workingDirectory = url.path }
                }.buttonStyle(PorticoButtonStyle())
            }
            Text(L10n.text("Залиште порожнім для запуску з папки .exe. Якщо гра шукає дані в іншому місці, вкажіть цю папку."))
                .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            Text(L10n.text("Аргументи запуску")).font(.system(size: 11, weight: .medium)).padding(.top, 6)
            Text(L10n.text("Кожне поле — один аргумент, навіть із пробілами. Зовнішні лапки не потрібні."))
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
            ForEach($arguments) { $argument in
                HStack(spacing: 8) {
                    TextField(L10n.text("Аргумент"), text: $argument.value).textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button { arguments.removeAll { $0.id == argument.id } } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.plain).help(L10n.text("Видалити аргумент"))
                }
            }
            Button(L10n.text("Додати аргумент")) { arguments.append(GameArgumentDraft(value: "")) }
                .buttonStyle(PorticoButtonStyle())
        }
    }
}
