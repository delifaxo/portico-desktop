import SwiftUI
import AppKit
import PorticoCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var crashReport: CrashReport?
    var body: some View {
        VStack(spacing: 0) {
            PorticoNavigation(model: model)
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
            if model.section == .library {
                GalleryLibraryView(model: model)
            } else {
                PorticoUtilityBar(model: model).padding(.horizontal, 36).padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        switch model.section {
                        case .library: EmptyView()
                        case .steam: SteamView(model: model)
                        case .bottles: bottlesPage
                        case .runtime: runtimePage
                        case .logs: logsPage
                        case .settings: CoolingSettingsView(cooling: model.cooling, model: model)
                        case .setup: SetupGuideView(model: model)
                        }
                    }.padding(36).frame(maxWidth: 1450, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .tint(Palette.mint)
        .onReceive(NotificationCenter.default.publisher(for: CrashReportText.openNotification)) { notification in
            openReport(kind: notification.object as? FeedbackKind ?? .crash)
        }
        .sheet(item: Binding(get: { model.sheet == nil ? crashReport : nil }, set: { crashReport = $0 })) { report in
            CrashReportView(model: model, report: report)
        }
        .sheet(item: $model.sheet) { item in
            Group {
            switch item {
            case .createBottle: CreateBottleSheet(model: model)
            case .addGame: GameEditorSheet(model: model)
            case .editGame(let id):
                if let game = model.library.games.first(where: { $0.id == id }) {
                    GameEditorSheet(model: model, game: game)
                }
            case .gameParameters(let id):
                if let game = model.library.games.first(where: { $0.id == id }) {
                    GameEditorSheet(model: model, game: game, showLaunchSettings: true)
                }
            case .runtimeSetup: RuntimeSetupView(model: model)
            case .graphicsSetup: GraphicsSetupView(model: model)
            case .crossOverImport: CrossOverImportSheet(model: model)
            case .launchGuide(let game): GameLaunchGuideSheet(model: model, game: game)
            case .removeGame(let target): GameRemovalSheet(model: model, target: target)
            }
            }.sheet(item: $crashReport) { report in CrashReportView(model: model, report: report) }
        }
        .alert(item: $model.notice) { notice in
            if notice.reportable {
                return Alert(title: Text(notice.title), message: Text(notice.message),
                             primaryButton: .default(Text(CrashReportText.text("Репорт…", "Report…"))) { openReport(error: notice) },
                             secondaryButton: .cancel(Text(L10n.text("Скасувати"))))
            }
            return Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text(L10n.text("Зрозуміло"))))
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
            if dismissed && crashReport == nil { model.offerGraphicsOnFirstLaunch() }
        }
        .onChange(of: model.engineReady) { _, ready in
            if ready { model.offerGraphicsOnFirstLaunch() }
        }
    }

    private func openReport(error: Notice? = nil, kind: FeedbackKind = .crash) {
        let report = model.makeCrashReport(error: error, kind: kind)
        // Present above an existing editor so cancelling preserves its unsaved fields.
        // Defer presentation until any error alert has finished dismissal.
        DispatchQueue.main.async { crashReport = report }
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
                Button { openReport() } label: { Label(CrashReportText.text("Повідомити про збій", "Report a crash"), systemImage: "cross.case") }.buttonStyle(PorticoButtonStyle())
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
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
                }.frame(minHeight: 440, maxHeight: 650).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.separator))
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

private extension View {
    func panel() -> some View {
        self.background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.separator, lineWidth: 1))
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
