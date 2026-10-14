import SwiftUI
import PorticoCore

/// A repeatable, app-wide initialization guide. Completion labels describe
/// detected local prerequisites, never an assumed successful game launch.
struct SetupGuideView: View {
    @ObservedObject var model: AppModel
    @State private var bottleID: UUID?
    @State private var steamRoute = true
    private var selectedBottle: Bottle? { model.readyBottles.first { $0.id == bottleID } }
    private var clientInstalled: Bool { bottleID.flatMap { model.steamClients[$0] } != nil }
    private var installedGames: [SteamInstalledGame] { bottleID.flatMap { model.steamInstalledGames[$0] } ?? [] }
    private var cards: [Game] { model.library.games.filter { $0.bottleID == bottleID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("Як налаштувати Portico")).font(.system(size: 30, weight: .semibold))
                    Text(L10n.text("Пройдіть кроки по черзі. Інструкція підходить для різних Windows-ігор і завжди доступна в розділі «Початок роботи»."))
                        .font(.system(size: 13)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(L10n.text("Перевірити знову")) { refresh() }.buttonStyle(PorticoButtonStyle())
                    .accessibilityIdentifier("setup-guide-refresh")
            }
            guideStep(1, title: L10n.text("Підключіть рушій Wine"), complete: model.engineReady, status: model.engineReady ? L10n.text("Рушій перевірено") : L10n.text("Потрібне налаштування")) {
                detail(L10n.text("У повній збірці Wine вже вбудований. Натисніть «Перевірити вбудований Wine» і дочекайтеся результату. Якщо рушія немає, відкрийте його встановлення та натисніть кнопку завантаження."))
                if !model.rosettaAvailable {
                    Label(L10n.text("Для Intel-версії Wine на Apple Silicon потрібна Rosetta 2. Завершіть її встановлення в системному вікні macOS, потім повторіть перевірку рушія."), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Palette.amber)
                }
                HStack {
                    if model.hasBundledRuntime {
                        Button(L10n.text("Перевірити вбудований Wine")) { Task { await model.useBundledRuntime() } }
                            .buttonStyle(PorticoButtonStyle(primary: !model.engineReady)).disabled(model.isProbing || model.activeDownload != nil)
                            .accessibilityIdentifier("setup-guide-check-wine")
                    }
                    Button(L10n.text("Встановити або вибрати рушій…")) { model.sheet = .runtimeSetup }
                        .buttonStyle(PorticoButtonStyle()).accessibilityIdentifier("setup-guide-runtime")
                    if model.isProbing { ProgressView().controlSize(.small) }
                }
                if model.engineReady { detail(model.engineVersion) }
            }

            guideStep(2, title: L10n.text("Виберіть графіку для своїх ігор"), complete: nil, status: L10n.text("Залежить від вимог гри")) {
                detail(L10n.text("Подивіться версію DirectX у системних вимогах гри. Для DirectX 9 почніть із вбудованого Wine; профіль DirectX 9 вмикається пізніше в шестерні гри. Для DirectX 11/12 підключіть сумісний комплект Wine + D3DMetal перед створенням середовища."))
                HStack {
                    Label(model.graphicsInstalled ? L10n.text("D3DMetal підключено") : L10n.text("D3DMetal — за потреби"), systemImage: "display")
                        .font(.system(size: 11)).foregroundStyle(model.graphicsInstalled ? Palette.mint : Palette.muted)
                    Spacer()
                    Button(L10n.text("Налаштувати DirectX 11/12…")) { model.sheet = .graphicsSetup }
                        .buttonStyle(PorticoButtonStyle()).disabled(DistributionPolicy.isAppStore)
                        .accessibilityIdentifier("setup-guide-graphics")
                }
                detail(L10n.text("У вікні DirectX 11/12 є посилання на джерело та підключення локального комплекту. Потрібен повний сумісний рушій із Wine та D3DMetal."))
            }

            guideStep(3, title: L10n.text("Створіть Windows-середовище"), complete: selectedBottle != nil,
                      status: selectedBottle == nil ? L10n.text("Виберіть або створіть середовище") : L10n.text("Середовище готове")) {
                detail(L10n.text("Середовище — окрема Windows-папка з іграми та налаштуваннями. Натисніть «Створити середовище», виберіть звичайний Wine або D3DMetal і дочекайтеся готовності. Для ігор із різними вимогами можна створити кілька середовищ."))
                HStack {
                    if !model.readyBottles.isEmpty {
                        Picker(L10n.text("Середовище для наступних кроків"), selection: $bottleID) {
                            Text(L10n.text("Виберіть середовище")).tag(Optional<UUID>.none)
                            ForEach(model.readyBottles) { Text($0.name).tag(Optional($0.id)) }
                        }.accessibilityIdentifier("setup-guide-environment")
                    }
                    Button(L10n.text("Створити середовище…")) { model.sheet = .createBottle }
                        .buttonStyle(PorticoButtonStyle(primary: selectedBottle == nil))
                        .disabled(!model.engineReady && !model.graphicsExecutionAllowed)
                        .accessibilityIdentifier("setup-guide-create-bottle")
                }
                if let selectedBottle { detail(model.runtimeDescription(for: selectedBottle)) }
                ForEach(model.library.bottles.filter { $0.status != .ready }) { bottle in
                    HStack {
                        Text(bottle.name).font(.system(size: 12))
                        Spacer()
                        if bottle.status == .creating { ProgressView().controlSize(.small) }
                        else {
                            Button(L10n.text("Відкрити журнал")) { model.showLog(bottle) }.buttonStyle(PorticoButtonStyle())
                            Button(L10n.text("Повторити")) { model.retryBottle(bottle) }.buttonStyle(PorticoButtonStyle())
                                .disabled(model.isBusy(bottle))
                        }
                    }
                }
            }

            guideStep(4, title: L10n.text("Встановіть Steam або запустіть інсталятор гри"), complete: steamRoute ? clientInstalled : nil,
                      status: steamRoute && clientInstalled ? L10n.text("Клієнт Steam встановлено") : L10n.text("Виберіть спосіб встановлення")) {
                Picker(L10n.text("Спосіб встановлення"), selection: $steamRoute) {
                    Text("Steam").tag(true)
                    Text(L10n.text("Свій інсталятор .exe / .msi")).tag(false)
                }.pickerStyle(.segmented).accessibilityIdentifier("setup-guide-install-route")
                if steamRoute {
                    detail(L10n.text("Встановіть Windows-клієнт Steam у вибране середовище. Дочекайтеся завантаження й оновлення клієнта, потім увійдіть у своєму вікні Steam. Після входу відкрийте бібліотеку; пароль і Steam Guard вводяться лише в Steam."))
                    Button(clientInstalled ? L10n.text("Відкрити Steam") : L10n.text("Завантажити та встановити Steam")) {
                        guard let selectedBottle else { return }
                        if clientInstalled { model.steam(.library, in: selectedBottle) }
                        else { model.installSteam(in: selectedBottle) }
                    }.buttonStyle(PorticoButtonStyle(primary: true))
                        .disabled(selectedBottle.map { clientInstalled ? !model.canUseSteam(in: $0)
                            : model.isBusy($0) || model.steamInstallerDownloads.contains($0.id) } != false || DistributionPolicy.isAppStore)
                        .accessibilityIdentifier("setup-guide-steam")
                    if let bottleID, let message = model.steamMessages[bottleID] { detail(L10n.text(message)) }
                } else {
                    detail(L10n.text("Виберіть інсталятор своєї Windows-гри (.exe або .msi), пройдіть його кроки та встановіть гру на диск C: вибраного середовища. Потім знайдіть .exe встановленої гри для її запуску."))
                    Button(L10n.text("Відкрити інсталятор…")) {
                        if let selectedBottle { model.install(in: selectedBottle) }
                    }.buttonStyle(PorticoButtonStyle(primary: true))
                        .disabled(selectedBottle.map { model.isBusy($0) } != false || DistributionPolicy.isAppStore)
                        .accessibilityIdentifier("setup-guide-installer")
                }
                if selectedBottle == nil { detail(L10n.text("Спочатку виберіть готове середовище в кроці 3.")) }
            }

            guideStep(5, title: L10n.text("Додайте встановлену гру до Portico"), complete: !cards.isEmpty,
                      status: cards.isEmpty ? L10n.text("Додайте свою гру") : L10n.text("Ігри додано")) {
                if steamRoute {
                    detail(L10n.text("У бібліотеці Windows Steam встановіть потрібну гру й дочекайтеся завершення завантаження. Потім натисніть «Оновити список» і «Додати ігри зі Steam». Portico збереже запуск через Steam у тому самому середовищі."))
                    HStack {
                        Button(L10n.text("Оновити список")) { refresh() }.buttonStyle(PorticoButtonStyle()).disabled(selectedBottle == nil)
                        Button(L10n.text("Додати ігри зі Steam")) {
                            if let selectedBottle { model.importSteamGames(from: selectedBottle) }
                        }.buttonStyle(PorticoButtonStyle(primary: true)).disabled(installedGames.isEmpty)
                            .accessibilityIdentifier("setup-guide-import-steam")
                    }
                    if !installedGames.isEmpty { detail(installedGames.map(\.name).joined(separator: " · ")) }
                } else {
                    detail(L10n.text("Натисніть «Додати гру», виберіть те саме середовище та .exe встановленої гри. За потреби вкажіть робочу папку поруч із цим файлом."))
                    Button(L10n.text("Додати гру")) { model.newGameBottleID = bottleID; model.sheet = .addGame }.buttonStyle(PorticoButtonStyle(primary: true))
                        .disabled(selectedBottle == nil).accessibilityIdentifier("setup-guide-add-game")
                }
            }

            guideStep(6, title: L10n.text("Налаштуйте гру та перевірте запуск"), complete: nil, status: L10n.text("Перевіряється в самій грі")) {
                detail(L10n.text("Відкрийте шестерню картки. Перевірте спосіб запуску й середовище. Для DirectX 9 виберіть цей профіль, збережіть і застосуйте конфігурацію; якщо гра зі Steam містить кілька .exe, вкажіть файл самої гри. Для DirectX 11/12 використовуйте графіку відповідного середовища."))
                detail(L10n.text("Якщо гра повідомляє про відсутність D3DX9 або D3DCompiler, натисніть «Завантажити та встановити компоненти DirectX» і завершіть інсталятор. Якщо потрібні Visual C++, використовуйте комплект гри або її інсталятор залежностей."))
                detail(L10n.text("Натисніть кнопку запуску картки: відкриється перевірка перед запуском. Запустіть гру, дочекайтеся меню та перевірте ігровий епізод, звук і керування. Готовність компонентів ще не підтверджує сумісність кожної гри."))
                HStack {
                    Button(L10n.text("Перейти до бібліотеки")) { model.section = .library }
                        .buttonStyle(PorticoButtonStyle(primary: true)).accessibilityIdentifier("setup-guide-library")
                    if let selectedBottle {
                        Button(L10n.text("Відкрити журнал")) { model.showLog(selectedBottle) }.buttonStyle(PorticoButtonStyle())
                    }
                }
                DisclosureGroup(L10n.text("Якщо щось не запускається")) {
                    VStack(alignment: .leading, spacing: 10) {
                        detail(L10n.text("Немає вікна Steam або чорна бібліотека: дочекайтеся оновлення клієнта, відкрийте розділ Steam і його журнал. Перезапускайте клієнт після виходу з гри."))
                        detail(L10n.text("Application load error / no Steam apps: виберіть запуск через Steam і середовище, у якому встановлена ця гра."))
                        detail(L10n.text("Потрібен D3D feature level 12_0: використовуйте сумісний рушій D3DMetal і перевірте діагностику DirectX 12 вибраного середовища."))
                    }.padding(.top, 10)
                }.font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }
        .onAppear { if bottleID == nil, model.readyBottles.count == 1 { bottleID = model.readyBottles.first?.id }; refresh() }
        .onChange(of: bottleID) { _, _ in refresh() }
        .onChange(of: model.readyBottles.map(\.id)) { _, ids in
            if let bottleID, !ids.contains(bottleID) { self.bottleID = nil }
            if bottleID == nil, ids.count == 1 { bottleID = ids[0] }
            refresh()
        }
    }

    private func refresh() {
        model.refreshGraphics()
        if let selectedBottle { model.refreshSteam(in: selectedBottle) }
    }
    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }
    private func guideStep<Content: View>(_ number: Int, title: String, complete: Bool?, status: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(String(format: "%02d", number)).font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.mint).frame(width: 40, height: 40)
                .background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 12)
                    Label(status, systemImage: complete == true ? "checkmark.circle.fill" : complete == false ? "circle.dashed" : "info.circle")
                        .font(.system(size: 10)).foregroundStyle(complete == true ? Palette.mint : Palette.muted)
                }
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(22).background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
    }
}
