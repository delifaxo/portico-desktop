import SwiftUI
import AppKit
import PorticoCore

enum Palette {
    static let background = Color(hex: 0x101216)
    static let sidebar = Color(hex: 0x14171C)
    static let panel = Color(hex: 0x1A1E24)
    static let elevated = Color(hex: 0x22272F)
    static let mint = Color(hex: 0xBCF5C8)
    static let muted = Color(hex: 0x929BA7)
    static let amber = Color(hex: 0xEDC58B)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.055)).frame(width: 1)
            VStack(spacing: 0) {
                topbar
                Divider().overlay(.white.opacity(0.025))
                if model.isUISimulation {
                    Label(L10n.text("ТЕСТОВА КОПІЯ · Симулятор Wine не встановлює Steam і не запускає ігри для Windows."), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Palette.amber).padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.amber.opacity(0.08))
                        .accessibilityIdentifier("ui-simulation-banner")
                }
                if let problem = model.storageProblem {
                    Label(L10n.text("Помилка сховища: \(problem)"), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Palette.amber).padding()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        switch model.section {
                        case .library: libraryPage
                        case .steam: SteamView(model: model)
                        case .bottles: bottlesPage
                        case .runtime: runtimePage
                        case .logs: logsPage
                        case .settings: CoolingSettingsView(cooling: model.cooling, model: model)
                        case .setup: SetupGuideView(model: model)
                        }
                    }.padding(30).frame(maxWidth: 1450, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .background(Palette.background)
        .tint(Palette.mint)
        .sheet(item: $model.sheet) { item in
            switch item {
            case .createBottle: CreateBottleSheet(model: model)
            case .addGame: GameEditorSheet(model: model)
            case .editGame(let id):
                if let game = model.library.games.first(where: { $0.id == id }) {
                    GameEditorSheet(model: model, game: game)
                }
            case .runtimeSetup: RuntimeSetupView(model: model)
            case .graphicsSetup: GraphicsSetupView(model: model)
            case .crossOverImport: CrossOverImportSheet(model: model)
            case .launchGuide(let game): GameLaunchGuideSheet(model: model, game: game)
            }
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text(L10n.text("Зрозуміло"))))
        }
        .task {
            if !model.hasShownSetup {
                model.hasShownSetup = true
                if model.library.bottles.isEmpty && model.totalGameCount == 0 { model.section = .setup }
            }
            model.refreshGraphics()
            if !model.enginePathDraft.isEmpty && model.validatedEnginePath == nil { await model.probeEngine() }
            model.offerGraphicsOnFirstLaunch()
        }
        .onChange(of: model.sheet == nil) { _, dismissed in
            if dismissed { model.offerGraphicsOnFirstLaunch() }
        }
        .onChange(of: model.engineReady) { _, ready in
            if ready { model.offerGraphicsOnFirstLaunch() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Palette.mint).frame(width: 41, height: 41)
                    Image(systemName: "door.left.hand.open").font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.background)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Portico").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("WINDOWS → MAC").font(.system(size: 8, weight: .semibold)).tracking(2).foregroundStyle(Palette.muted)
                }
            }.padding(.bottom, 44)
            Text(L10n.text("ВАШ ПРОСТІР")).font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted).padding(.leading, 12).padding(.bottom, 13)
            ForEach(AppSection.allCases) { section in
                Button { model.section = section } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.symbol).font(.system(size: 16, weight: .medium)).frame(width: 22)
                        Text(section.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                        if section == .library {
                            Text("\(model.totalGameCount)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(model.section == section ? Palette.mint : Palette.muted)
                        }
                    }
                    .foregroundStyle(model.section == section ? Palette.mint : Color.white.opacity(0.65))
                    .padding(.horizontal, 12).padding(.vertical, 13)
                    .background(model.section == section ? Palette.mint.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).padding(.bottom, 5)
            }
            Spacer(minLength: 50)
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 9) {
                    Image(systemName: "desktopcomputer").font(.system(size: 19)).foregroundStyle(Palette.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Цей Mac")).font(.system(size: 12, weight: .semibold))
                        Text(hostArchitecture).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                }
                Divider()
                HStack(spacing: 6) {
                    Circle().fill(model.engineReady ? Palette.mint : Palette.amber).frame(width: 5, height: 5)
                    Text(model.engineReady ? L10n.text("Wine підключено") : L10n.text("Потрібен рушій Wine")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }.padding(14).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
            Text("PORTICO  /  PREVIEW " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "DEV")).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.3).foregroundStyle(Palette.muted.opacity(0.65)).padding(.top, 20).frame(maxWidth: .infinity)
        }.padding(.horizontal, 18).padding(.top, 52).padding(.bottom, 23)
            .frame(width: 218).frame(maxHeight: .infinity).background(Palette.sidebar)
    }

    private var hostArchitecture: String {
        #if arch(arm64)
        return "Apple Silicon · macOS"
        #else
        return "Intel · macOS"
        #endif
    }

    private var topbar: some View {
        HStack {
            Text(L10n.text("Робочий простір")).foregroundStyle(Palette.muted)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted.opacity(0.5)).padding(.horizontal, 3)
            Text(model.section.title).foregroundStyle(.white.opacity(0.88))
            Spacer()
            LanguagePicker(model: model).padding(.trailing, 12)
            if !model.operations.isEmpty {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(L10n.text("Активних середовищ: \(model.operations.count)")).foregroundStyle(Palette.mint)
            } else {
                Image(systemName: "circle.dotted").foregroundStyle(Palette.muted)
                Text(L10n.text("Локально на вашому Mac")).foregroundStyle(Palette.muted)
            }
        }.font(.system(size: 11)).padding(.horizontal, 30).frame(height: 66)
    }

    private var libraryPage: some View {
        Group {
            HStack(alignment: .top, spacing: 25) {
                VStack(alignment: .leading, spacing: 16) {
                    eyebrow(L10n.text("НОВИЙ ДІМ ДЛЯ ВАШИХ ІГОР"))
                    Text(L10n.text("Ігри для Windows.\nТепер ближче до Mac."))
                        .font(.system(size: 32, weight: .semibold)).tracking(-1.15).lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("Зберіть бібліотеку, налаштуйте середовище\nта запускайте ігри в одному місці."))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5)
                    HStack(spacing: 12) {
                        Button(action: primaryAction) {
                            Label(model.readyBottles.isEmpty ? L10n.text("Почати налаштування") : L10n.text("Додати гру"), systemImage: "plus")
                        }.buttonStyle(PorticoButtonStyle(primary: true))
                        Button { model.section = .steam } label: {
                            Label(L10n.text("Steam для Windows"), systemImage: "arrow.down.circle")
                        }.buttonStyle(PorticoButtonStyle())
                    }.padding(.top, 3)
                    Text(L10n.text("Готових середовищ: \(model.readyBottles.count)")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                PortalArtwork().frame(width: 285, height: 211).accessibilityHidden(true)
            }.padding(27).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [Color(hex: 0x202C2C), Color(hex: 0x1A2026), Palette.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.075), lineWidth: 1))

            VStack(alignment: .leading, spacing: 19) {
                HStack {
                    Text(L10n.text("Моя бібліотека")).font(.system(size: 20, weight: .semibold)).tracking(-0.4)
                    Text("\(model.totalGameCount)").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Palette.muted).padding(.horizontal, 7).padding(.vertical, 4).background(Palette.elevated, in: Capsule())
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                        TextField(L10n.text("Знайти гру"), text: $model.search).textFieldStyle(.plain)
                    }.font(.system(size: 11)).padding(10).frame(width: 180).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                    Button { model.sheet = .addGame } label: { Image(systemName: "plus").frame(width: 15, height: 15) }
                        .buttonStyle(PorticoButtonStyle()).disabled(model.readyBottles.isEmpty).help(L10n.text("Додати встановлену гру для Windows"))
                }
                if !DistributionPolicy.isAppStore {
                    Button { model.sheet = .crossOverImport } label: {
                        Label(cxText("Додати з CrossOver", "Add from CrossOver"), systemImage: "arrow.up.forward.app")
                    }.buttonStyle(PorticoButtonStyle())
                        .accessibilityIdentifier("crossover-import-open")
                }
                HStack(spacing: 6) {
                    ForEach(GameFilter.allCases) { filter in
                        Button { model.filter = filter } label: {
                            Text(filter.title).font(.system(size: 11, weight: .medium)).foregroundStyle(model.filter == filter ? .white : Palette.muted)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(model.filter == filter ? Palette.elevated : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                if model.totalGameCount == 0 {
                    libraryEmptyState
                } else if model.filteredGames.isEmpty && model.filteredCrossOverGames.isEmpty {
                    emptyPanel(symbol: "magnifyingglass", title: L10n.text("Ігор не знайдено"), detail: L10n.text("Змініть запит або виберіть інший фільтр."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                        ForEach(model.filteredGames) { game in gameCard(game) }
                        ForEach(model.filteredCrossOverGames) { game in CrossOverGameCard(model: model, game: game) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text(L10n.text("Ігри для перевірки")).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Text(L10n.text("ВИБРАНО ДЛЯ ПЕРЕВІРКИ")).font(.system(size: 8, weight: .medium)).tracking(1.4).foregroundStyle(Palette.muted)
                }
                Text(L10n.text("Додавайте будь-які встановлені ігри для Windows. Для кожної можна вибрати власне середовище й параметри запуску; сумісність перевіряється окремо."))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: 16) {
                    targetCard(title: "Heroes of Might and Magic III", subtitle: L10n.text("Оригінал / Complete"), symbol: "crown", color: Palette.amber, badge: L10n.text("Запуск ще не перевірено"), detail: L10n.text("Для оригіналу та Complete — окреме середовище. HD Edition і модифікації перевіряються окремо."), action: L10n.text("Complete на GOG"), url: "https://www.gog.com/en/game/heroes_of_might_and_magic_3_complete_edition")
                    targetCard(title: "Jagged Alliance 2", subtitle: L10n.text("Оригінал / Gold"), symbol: "scope", color: Palette.mint, badge: L10n.text("Запуск ще не перевірено"), detail: L10n.text("Окреме середовище й параметри гри. Оригінал, Unfinished Business і модифікації перевіряються окремо."), action: L10n.text("Сторінка Gold у Steam"), url: "https://store.steampowered.com/app/1620/Jagged_Alliance_2_Gold/")
                    targetCard(title: "Divinity: Original Sin 2", subtitle: "Definitive Edition", symbol: "sparkles", color: Color(hex: 0xDDB480), badge: L10n.text("Є версія для macOS"), detail: L10n.text("Гра має нативну версію для Mac. Версія для Windows потребує DirectX 11."), action: L10n.text("Відкрити в Steam"), url: "https://store.steampowered.com/app/435150/Divinity_Original_Sin_2__Definitive_Edition/")
                    targetCard(title: "Gothic 1 Remake", subtitle: "Windows · DirectX 12", symbol: "mountain.2", color: Color(hex: 0xA9B8D1), badge: L10n.text("Запуск ще не перевірено"), detail: L10n.text("Потрібен рушій із підтримкою DirectX 12 → Metal. Звичайного Wine недостатньо."), action: L10n.text("Вимоги гри"), url: "https://store.steampowered.com/app/1297900/Gothic_1_Remake/")
                }
            }
        }
    }

    private var libraryEmptyState: some View {
        HStack(alignment: .center, spacing: 25) {
            ZStack {
                RoundedRectangle(cornerRadius: 17).fill(Palette.elevated).frame(width: 68, height: 68).rotationEffect(.degrees(-6))
                Image(systemName: "gamecontroller").font(.system(size: 27, weight: .light)).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text("Тут буде ваша перша гра")).font(.system(size: 15, weight: .medium))
                Text(L10n.text("Почніть із Wine та окремого середовища.\nПотім установіть гру або додайте готовий .exe."))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 13) {
                setupStep("01", L10n.text("Підключити Wine"), done: model.engineReady) { model.section = .runtime }
                setupStep("02", L10n.text("Створити середовище"), done: !model.readyBottles.isEmpty) { beginBottleSetup() }
                setupStep("03", L10n.text("Додати гру"), done: false) { primaryAction() }
            }
        }.padding(25).frame(maxWidth: .infinity, minHeight: 159)
            .background(Palette.panel.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.095), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
    }

    private func setupStep(_ number: String, _ title: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint).frame(width: 17) }
                else { Text(number).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).frame(width: 17) }
                Text(title).font(.system(size: 10)).foregroundStyle(done ? Palette.mint : Palette.muted)
                Image(systemName: "arrow.up.right").font(.system(size: 8)).foregroundStyle(Palette.muted.opacity(0.6))
            }
        }.buttonStyle(.plain)
    }

    private func gameCard(_ game: Game) -> some View {
        let bottle = model.bottle(for: game)
        let running = model.runningGames[game.id] != nil
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Color(hex: 0x344E49), Color(hex: 0x262935), Palette.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "gamecontroller").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(Palette.mint.opacity(0.45)).frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(String(game.name.prefix(1)).uppercased()).font(.system(size: 115, weight: .black, design: .rounded)).foregroundStyle(.white.opacity(0.035)).offset(x: -12, y: -7)
                Button { model.toggleFavorite(game) } label: {
                    Image(systemName: game.isFavorite ? "star.fill" : "star").font(.system(size: 12)).foregroundStyle(game.isFavorite ? Palette.amber : .white.opacity(0.7)).padding(9).background(.black.opacity(0.18), in: Circle())
                }.buttonStyle(.plain).padding(12).help(game.isFavorite ? L10n.text("Вилучити з обраного") : L10n.text("До обраного"))
            }.frame(height: 123).clipped()
            VStack(alignment: .leading, spacing: 10) {
                Text(game.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Label(game.effectiveLaunchMethod == .crossOver ? game.crossOverLauncher?.bottleName ?? "CrossOver" : bottle?.name ?? L10n.text("Середовище недоступне"), systemImage: "shippingbox").font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                if game.effectiveLaunchMethod == .steam {
                    Label(L10n.text("Steam · Windows"), systemImage: "gamecontroller").font(.system(size: 9)).foregroundStyle(Palette.mint)
                } else {
                    Label(game.effectiveLaunchMethod.label, systemImage: game.effectiveLaunchMethod == .crossOver ? "arrow.up.forward.app" : "app.badge")
                        .font(.system(size: 9)).foregroundStyle(Palette.mint)
                }
                HStack {
                    if running, let bottle {
                        Button { model.stop(bottle) } label: { Label(L10n.text("Зупинити"), systemImage: "stop.fill") }.buttonStyle(PorticoButtonStyle())
                    } else {
                        Button { model.launch(game) } label: { Label(L10n.text("Грати"), systemImage: "play.fill") }
                            .buttonStyle(PorticoButtonStyle(primary: true))
                            .accessibilityIdentifier("game-play-\(game.id.uuidString)")
                    }
                    Spacer()
                    Button { model.sheet = .editGame(game.id) } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).help(L10n.text("Налаштування гри"))
                        .accessibilityLabel(L10n.text("Налаштування гри"))
                        .accessibilityIdentifier("game-settings-\(game.id.uuidString)")
                    if let bottle {
                        Button { model.showLog(bottle) } label: { Image(systemName: "text.alignleft") }.buttonStyle(.plain).foregroundStyle(Palette.muted).help(L10n.text("Журнал запуску"))
                    }
                }.padding(.top, 5)
            }.padding(16)
        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 13)).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.06)))
            .contextMenu {
                Button(L10n.text("Налаштування гри…")) { model.sheet = .editGame(game.id) }
                Button(L10n.text("Інструкція та підготовка…")) { model.launch(game) }
                Button(game.effectiveLaunchMethod == .steam ? L10n.text("Показати папку гри у Finder") : L10n.text("Показати файл у Finder")) {
                    let path = game.effectiveLaunchMethod == .crossOver ? game.crossOverLauncher?.launcherPath ?? game.executablePath
                        : game.effectiveLaunchMethod == .steam ? game.workingDirectory ?? game.executablePath : game.executablePath
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button(game.isFavorite ? L10n.text("Вилучити з обраного") : L10n.text("До обраного")) { model.toggleFavorite(game) }
                Divider()
                Button(L10n.text("Вилучити з бібліотеки")) { model.removeGame(game) }.disabled(running)
            }
    }

    private func targetCard(title: String, subtitle: String, symbol: String, color: Color, badge: String, detail: String, action: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 23, weight: .light)).foregroundStyle(color).frame(width: 43, height: 48)
                    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            Text(badge).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            Text(detail).font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 32, alignment: .top)
            Button { model.openURL(url) } label: {
                HStack(spacing: 7) { Text(action); Image(systemName: "arrow.up.right").font(.system(size: 8)) }.font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }.buttonStyle(.plain)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).panel()
    }

    private var bottlesPage: some View {
        Group {
            pageTitle(L10n.text("Середовища"), detail: L10n.text("Окреме середовище Windows для кожної гри або лаунчера.")) {
                Button(action: beginBottleSetup) { Label(L10n.text("Створити середовище"), systemImage: "plus") }.buttonStyle(PorticoButtonStyle(primary: true))
            }
            HStack(spacing: 13) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 24, weight: .light)).foregroundStyle(Palette.mint)
                Text(L10n.text("Кожне середовище має власний диск C:, реєстр і налаштування Wine. Версія рушія фіксується під час створення."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                Spacer()
            }.padding(20).panel()
            if model.library.bottles.isEmpty {
                emptyPanel(symbol: "shippingbox", title: L10n.text("Створіть перше середовище"), detail: L10n.text("Підключіть Wine у розділі «Рушій», потім створіть середовище для встановлення ігор."))
            } else {
                ForEach(model.library.bottles) { bottle in
                    VStack(alignment: .leading, spacing: 19) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "shippingbox").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.mint).frame(width: 50, height: 50).background(Palette.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(bottle.name).font(.system(size: 18, weight: .semibold))
                                Text(L10n.text("Ігор: \(model.library.games.filter { $0.bottleID == bottle.id }.count) · Створено \(bottle.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(model.language.locale)))")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            if model.isBusy(bottle) { ProgressView().controlSize(.small) }
                            statusBadge(bottle)
                        }
                        Text(model.operations[bottle.id].map { L10n.text($0) } ?? bottle.enginePath).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(2).textSelection(.enabled)
                        if bottle.graphics?.backend == .d3dMetal {
                            GraphicsBottleStatus(model: model, bottle: bottle)
                        }
                        HStack(spacing: 9) {
                            if bottle.status == .failed {
                                Button { model.retryBottle(bottle) } label: { Label(L10n.text("Повторити підготовку"), systemImage: "arrow.clockwise") }.buttonStyle(PorticoButtonStyle(primary: true)).disabled(model.isBusy(bottle))
                            } else {
                                Button { model.install(in: bottle) } label: { Label(L10n.text("Встановити .exe / .msi"), systemImage: "square.and.arrow.down") }.buttonStyle(PorticoButtonStyle(primary: true)).disabled(bottle.status != .ready || model.isBusy(bottle))
                                Button { model.configure(bottle) } label: { Label(L10n.text("Налаштування Wine"), systemImage: "slider.horizontal.3") }.buttonStyle(PorticoButtonStyle()).disabled(bottle.status != .ready || model.isBusy(bottle))
                            }
                            Button { model.revealBottle(bottle) } label: { Image(systemName: "folder") }.buttonStyle(PorticoButtonStyle()).help(L10n.text("Відкрити середовище у Finder"))
                            Button { model.showLog(bottle) } label: { Image(systemName: "text.alignleft") }.buttonStyle(PorticoButtonStyle()).help(L10n.text("Відкрити журнал"))
                            Spacer()
                            if model.isBusy(bottle) {
                                Button { model.stop(bottle) } label: { Label(L10n.text("Зупинити"), systemImage: "stop.fill") }.buttonStyle(PorticoButtonStyle())
                            }
                        }
                    }.padding(22).panel()
                }
            }
        }
    }

    private var runtimePage: some View {
        Group {
            pageTitle(L10n.text("Рушій сумісності"), detail: model.hasBundledRuntime ? L10n.text("Wine та медіабібліотеки доступні у складі Portico.") : L10n.text("Підключіть установлений Wine, щоб запускати програми для Windows.")) {
                Button { model.refreshRuntimes() } label: { Label(L10n.text("Знайти рушії"), systemImage: "arrow.clockwise") }.buttonStyle(PorticoButtonStyle())
            }
            if model.hasBundledRuntime || DistributionPolicy.isAppStore {
                BundledRuntimeCard(model: model)
            }
            GraphicsRuntimeCard(model: model)
            VStack(alignment: .leading, spacing: 21) {
                HStack(alignment: .top, spacing: 15) {
                    Image(systemName: "cpu").font(.system(size: 29, weight: .light)).foregroundStyle(Palette.mint).frame(width: 57, height: 57).background(Palette.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.engineReady ? L10n.text("Wine підключено") : L10n.text("Підключіть ваш Wine")).font(.system(size: 20, weight: .semibold))
                        Text(model.hasBundledRuntime ? L10n.text("Для нових середовищ можна вибрати вбудований або власний рушій.") : L10n.text("Portico керує іграми та середовищами. Рушій встановлюється окремо.")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Image(systemName: model.engineReady ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(model.engineReady ? Palette.mint : Palette.muted).font(.system(size: 22))
                }
                if !DistributionPolicy.isAppStore {
                if !model.hasBundledRuntime { HStack(spacing: 12) {
                    Button { model.sheet = .runtimeSetup } label: { Label(L10n.text("Завантажити Wine"), systemImage: "arrow.down.circle") }
                        .buttonStyle(PorticoButtonStyle(primary: true))
                    Text(L10n.text("Wine Stable 11.0 · 185 МБ · SHA-256")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer()
                } }
                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("Шлях до виконуваного файлу Wine")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                    HStack(spacing: 9) {
                        TextField("/Applications/…/bin/wine", text: $model.enginePathDraft).font(.system(size: 12, design: .monospaced)).textFieldStyle(.plain).padding(12).background(Palette.background, in: RoundedRectangle(cornerRadius: 8)).disabled(model.isProbing).onSubmit { Task { await model.probeEngine() } }
                        Button(L10n.text("Вибрати…")) { model.chooseEngine() }.buttonStyle(PorticoButtonStyle()).disabled(model.isProbing)
                    }
                }
                HStack(spacing: 14) {
                    Button { Task { await model.probeEngine() } } label: {
                        Label(model.isProbing ? L10n.text("Перевірка…") : L10n.text("Перевірити й зберегти"), systemImage: "checkmark.shield")
                    }.buttonStyle(PorticoButtonStyle(primary: true)).disabled(model.isProbing || model.enginePathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.isProbing { ProgressView().controlSize(.small) }
                    if model.engineReady { Text(model.engineVersion).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.mint).lineLimit(2).textSelection(.enabled) }
                    Spacer()
                }
                if !model.runtimes.isEmpty {
                    Divider()
                    Text(L10n.text("Знайдено на цьому Mac")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                    ForEach(model.runtimes) { runtime in
                        Button { model.enginePathDraft = runtime.executableURL.path; Task { await model.probeEngine() } } label: {
                            HStack {
                                Image(systemName: "shippingbox")
                                Text(runtime.name)
                                Spacer()
                                Text(runtime.executableURL.path).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.muted)
                                Image(systemName: "arrow.right")
                            }.font(.system(size: 11)).padding(11).background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(model.isProbing)
                    }
                }
                } else {
                    Text(L10n.text("Ця збірка використовує рушій, що входить до застосунку. Підготовка середовищ виконується локально."))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }.padding(25).panel()

            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("Графіка та сумісність")).font(.system(size: 17, weight: .semibold))
                runtimeFact(symbol: "checkmark.circle", title: L10n.text("Перевірка Wine"), text: L10n.text("Підтверджує доступність wine і wineserver. Підтримку конкретної гри перевіряють окремим запуском."))
                runtimeFact(symbol: "cube.transparent", title: "DirectX → Metal", text: L10n.text("Виберіть D3DMetal під час створення нового середовища. Portico завантажить окремий рушій і перевірить DirectX 12 на цьому Mac."))
                runtimeFact(symbol: "mountain.2", title: "Gothic 1 Remake", text: L10n.text("Потребує DirectX 12. Сумісність і продуктивність на цьому Mac ще не перевірено."))
            }.padding(24).panel()

            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("Діагностика")).font(.system(size: 17, weight: .semibold))
                Toggle(isOn: Binding(get: { model.library.settings.verboseLogging }, set: model.setVerbose)) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("Розширений журнал Wine")).font(.system(size: 12, weight: .medium))
                        Text(L10n.text("Застосується під час наступного запуску. Допомагає з'ясовувати причини помилок запуску та встановлення.")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }.toggleStyle(.switch)
            }.padding(24).panel()
            HStack(spacing: 19) {
                Button { model.openURL("https://www.winehq.org/") } label: { Label(L10n.text("Про Wine"), systemImage: "arrow.up.right") }
                Button { model.openURL("https://developer.apple.com/games/game-porting-toolkit/") } label: { Label("Apple Game Porting Toolkit", systemImage: "arrow.up.right") }
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private var logsPage: some View {
        Group {
            pageTitle(L10n.text("Журнал"), detail: L10n.text("Вивід Wine та помилки останнього запуску у вибраному середовищі.")) {
                Button { model.exportLog() } label: { Label(L10n.text("Експорт"), systemImage: "square.and.arrow.up") }.buttonStyle(PorticoButtonStyle()).disabled(model.logText.isEmpty)
            }
            if model.library.bottles.isEmpty {
                emptyPanel(symbol: "text.alignleft", title: L10n.text("Поки без подій"), detail: L10n.text("Після створення середовища тут з'явиться журнал Wine."))
            } else {
                HStack {
                    Picker(L10n.text("Середовище"), selection: $model.logBottleID) {
                        ForEach(model.library.bottles) { bottle in Text(bottle.name).tag(Optional(bottle.id)) }
                    }.frame(maxWidth: 360).onChange(of: model.logBottleID) { _, _ in model.refreshLog() }
                    Spacer()
                    Text(L10n.text("ОСТАННІ 100 КБ")).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(Palette.muted)
                    Button { model.refreshLog() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(PorticoButtonStyle()).help(L10n.text("Оновити журнал"))
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(model.logText.isEmpty ? L10n.text("Очікування виводу Wine…") : model.logText)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(hex: 0xB7C8BD)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
                }.frame(minHeight: 440, maxHeight: 650).background(Color(hex: 0x0C100E), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08)))
                    .task {
                        while !Task.isCancelled {
                            model.refreshLog()
                            do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        }
                    }
            }
        }.onAppear { model.refreshLog() }
    }

    private func runtimeFact(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(Palette.mint).frame(width: 25).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func pageTitle<Actions: View>(_ title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 29, weight: .semibold)).tracking(-0.8)
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 15)
            actions()
        }
    }
    private func emptyPanel(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 35, weight: .ultraLight)).foregroundStyle(Palette.muted).padding(.bottom, 6)
            Text(title).font(.system(size: 17, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 460)
        }.frame(maxWidth: .infinity).padding(.vertical, 60).panel()
    }
    private func statusBadge(_ bottle: Bottle) -> some View {
        let color = bottle.status == .ready ? Palette.mint : Palette.amber
        let title = bottle.status == .ready ? L10n.text("Готово") : bottle.status == .creating ? L10n.text("Підготовка") : L10n.text("Помилка підготовки")
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.system(size: 10, weight: .medium))
        }.foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 7).background(color.opacity(0.08), in: Capsule())
    }
    private func eyebrow(_ text: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.mint).frame(width: 4, height: 4)
            Text(text).font(.system(size: 8, weight: .semibold)).tracking(1.8).foregroundStyle(Palette.mint)
        }
    }
    private func beginBottleSetup() {
        if model.engineReady { model.sheet = .createBottle } else { model.sheet = .runtimeSetup }
    }
    private func primaryAction() {
        if !model.readyBottles.isEmpty { model.sheet = .addGame } else { model.section = .setup }
    }
}

struct PortalArtwork: View {
    var body: some View {
        ZStack {
            Circle().fill(Palette.mint.opacity(0.04)).frame(width: 224, height: 224).blur(radius: 15)
            Ellipse().fill(.black.opacity(0.2)).frame(width: 195, height: 23).blur(radius: 10).offset(y: 88)
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [Palette.mint.opacity(0.025 + Double(index) * 0.018), Color(hex: 0x1C292C)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(LinearGradient(colors: [Palette.mint.opacity(0.12 + Double(index) * 0.08), Palette.mint.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    .frame(width: 128, height: 157)
                    .rotation3DEffect(.degrees(-25), axis: (x: 0, y: 1, z: 0))
                    .rotationEffect(.degrees(-12))
                    .offset(x: CGFloat(index - 2) * 23, y: CGFloat(2 - index) * 8)
            }
            Image(systemName: "gamecontroller.fill").font(.system(size: 43, weight: .light)).foregroundStyle(Palette.mint)
                .rotationEffect(.degrees(-12)).offset(x: 35, y: -8).shadow(color: Palette.mint.opacity(0.3), radius: 25)
            Text("PLAY BEYOND").font(.system(size: 7, weight: .semibold, design: .monospaced)).tracking(2.3).foregroundStyle(Palette.mint.opacity(0.55)).rotationEffect(.degrees(-12)).offset(x: 50, y: 35)
            Image(systemName: "plus").font(.system(size: 12, weight: .ultraLight)).foregroundStyle(Palette.mint.opacity(0.5)).offset(x: -102, y: -90)
            Image(systemName: "plus").font(.system(size: 8, weight: .ultraLight)).foregroundStyle(Palette.mint.opacity(0.4)).offset(x: 134, y: 62)
        }
    }
}

struct PorticoButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .semibold))
            .foregroundStyle(primary ? Palette.background : Color.white.opacity(0.84))
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(primary ? Palette.mint : Palette.elevated, in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private extension View {
    func panel() -> some View {
        self.background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.06), lineWidth: 1))
    }
}

private struct CreateBottleSheet: View {
    @ObservedObject var model: AppModel
    @State private var name = L10n.text("Ігрове середовище")
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(L10n.text("Нове середовище"), systemImage: "shippingbox").font(.system(size: 23, weight: .semibold))
            Text(L10n.text("Portico створить окремий диск C: і реєстр Windows. Перша підготовка може тривати кілька хвилин.")).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Назва")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                TextField(L10n.text("Наприклад, Jagged Alliance 2"), text: $name).textFieldStyle(.roundedBorder)
            }
            Picker(L10n.text("Графіка"), selection: $model.newBottleGraphics) {
                Text(L10n.text("Графіка Wine (типово)")).tag(GraphicsBackend.wineDefault)
                if !DistributionPolicy.isAppStore {
                    Text("DirectX 12 · D3DMetal").tag(GraphicsBackend.d3dMetal)
                }
            }.pickerStyle(.radioGroup)
            if model.newBottleGraphics == .d3dMetal {
                Text(L10n.text("Окремий рушій для DirectX 12. Наявні середовища зберігають свою версію Wine.")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                if !model.graphicsInstalled || !model.graphicsExecutionAllowed {
                    Button(model.graphicsInstalled ? L10n.text("Налаштувати DirectX 12") : L10n.text("Підключити DirectX 12…")) { model.sheet = .graphicsSetup }
                        .buttonStyle(PorticoButtonStyle(primary: true))
                }
            } else {
                Label(model.engineVersion.isEmpty ? "Wine" : model.engineVersion, systemImage: "cpu").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            HStack {
                Spacer()
                Button(L10n.text("Скасувати")) { model.sheet = nil }.buttonStyle(PorticoButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L10n.text("Створити середовище")) { model.createBottle(name: name, graphics: model.newBottleGraphics) }.buttonStyle(PorticoButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.newBottleGraphics == .d3dMetal ? !model.graphicsExecutionAllowed : !model.engineReady))
            }
        }.padding(30).frame(width: 500).background(Palette.sidebar).task { await model.assessGraphics() }
    }
}
