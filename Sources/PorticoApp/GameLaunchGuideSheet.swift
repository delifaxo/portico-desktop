import SwiftUI
import PorticoCore

struct GameLaunchGuideSheet: View {
    @ObservedObject var model: AppModel
    let game: Game
    @State private var installed = false
    @State private var clientInstalled = false
    @State private var launchFilesValid = false
    @State private var graphicsStatus: GameGraphics.Status?
    @State private var checkError: String?
    @State private var didCheck = false

    private var bottle: Bottle? { model.bottle(for: game) }
    private var isSteam: Bool { game.effectiveLaunchMethod == .steam }
    private var isCrossOver: Bool { game.effectiveLaunchMethod == .crossOver }
    private var usesDirectX9: Bool { !isCrossOver && game.effectiveGraphicsProfile == .directX9 }
    private var working: Bool { model.preparingGames.contains(game.id) }
    private var componentsReady: Bool {
        isCrossOver || graphicsStatus?.configured == true || (checkError == nil && model.preparedGames.contains(game.id))
    }
    private var ready: Bool {
        didCheck && launchFilesValid && (!isSteam || installed && clientInstalled)
            && componentsReady && model.canLaunch(game) && !working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "list.bullet.clipboard.fill").font(.system(size: 23))
                    .foregroundStyle(Palette.mint).frame(width: 48, height: 48)
                    .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("Перед запуском")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Text(game.name).font(.system(size: 22, weight: .semibold)).lineLimit(2)
                }
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    routePanel
                    if usesDirectX9 || graphicsStatus?.needsRestore == true { graphicsPreparation }
                    instructions
                    if let error = model.gamePreparationErrors[game.id] ?? checkError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Palette.amber).textSelection(.enabled)
                    }
                    installationActions
                    if !ready, let bottle, let operation = model.operations[bottle.id], !working {
                        Text(L10n.text(operation)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }.padding(.trailing, 4)
            }.frame(maxHeight: 470)
            HStack(spacing: 10) {
                Button(L10n.text("Закрити")) { model.sheet = nil }
                    .buttonStyle(PorticoButtonStyle()).disabled(working)
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("launch-guide-close")
                Button { model.editGameFromGuide(game) } label: {
                    Label(L10n.text("Налаштування гри"), systemImage: "gearshape")
                }.buttonStyle(PorticoButtonStyle()).disabled(working || isCrossOver && !model.library.games.contains(where: { $0.id == game.id }))
                    .accessibilityIdentifier("launch-guide-settings")
                Spacer()
                Button { recheck(); if ready { model.launchPrepared(game) } } label: {
                    Label(L10n.text("Запустити гру"), systemImage: "play.fill")
                }.buttonStyle(PorticoButtonStyle(primary: true)).disabled(!ready)
                    .accessibilityIdentifier("launch-guide-launch")
            }
        }.padding(28).frame(width: 650).background(Palette.background)
            .interactiveDismissDisabled(working)
            .task { recheck() }
            .onChange(of: working) { _, busy in if !busy { recheck() } }
    }

    private var routePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(game.effectiveLaunchMethod.label, systemImage: isCrossOver ? "arrow.up.forward.app" : "gamecontroller")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.mint)
            if isCrossOver {
                Text(game.crossOverLauncher?.bottleName ?? "CrossOver")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else if let bottle {
                Text(bottle.name).font(.system(size: 13, weight: .medium))
                Text(model.runtimeDescription(for: bottle)).font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else {
                Text(L10n.text("Середовище недоступне")).foregroundStyle(Palette.amber)
            }
            HStack(spacing: 16) {
                check(L10n.text("Файли гри"), good: launchFilesValid && (!isSteam || installed))
                if isSteam { check("Steam", good: clientInstalled) }
                if usesDirectX9 { check("DirectX 9", good: componentsReady) }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(L10n.text("Встановлення та запуск")).font(.system(size: 14, weight: .semibold))
            if isCrossOver {
                step("1", L10n.text("Встановіть гру в CrossOver"), L10n.text("Використовуйте її середовище та ярлик, створений CrossOver."))
                step("2", L10n.text("Відкрийте вибраний ярлик"), L10n.text("Portico відкриє встановлений CrossOver з його налаштуваннями гри."))
            } else if isSteam {
                step("1", L10n.text("Встановіть гру в Steam"), L10n.text("Увійдіть у Windows-клієнт Steam вибраного середовища та дочекайтеся завершення завантаження гри."))
                if usesDirectX9 {
                    step("2", L10n.text("Підготуйте DirectX 9"), L10n.text("Застосуйте графічний профіль. Якщо гра потребує старих бібліотек DirectX, встановіть компоненти окремою кнопкою."))
                } else if game.steamAppID == "1771300" || game.steamAppID == "1297900" {
                    step("2", L10n.text("Перевірте графічне середовище"), L10n.text("Для цієї гри використовуйте перевірене середовище D3DMetal. Змінити його можна у способі запуску."))
                } else {
                    step("2", L10n.text("Дочекайтеся встановлення компонентів"), L10n.text("Під час першого запуску Steam може встановити DirectX і Visual C++. Завершіть ці інсталятори."))
                }
                step("3", L10n.text("Запускайте через Steam"), L10n.text("Натисніть «Запустити гру». Portico передасть її App ID клієнту Steam у цьому середовищі."))
            } else {
                step("1", L10n.text("Встановіть гру в середовище"), L10n.text("Скористайтеся інсталятором гри та виберіть .exe самої гри у способі запуску."))
                step("2", L10n.text("Перевірте компоненти та робочу папку"), L10n.text("Встановіть залежності з комплекту гри. Робоча папка зазвичай містить її .exe."))
                if game.steamAppID != nil {
                    Text(L10n.text("Для копії зі Steam рекомендовано спосіб запуску Steam: прямий запуск .exe може спричинити Application load error."))
                        .font(.system(size: 12)).foregroundStyle(Palette.amber)
                }
            }
        }
    }

    private var graphicsPreparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.text("Графіка гри"), systemImage: "display")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if working { ProgressView().controlSize(.small) }
                else if componentsReady { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint) }
            }
            Text(game.effectiveGraphicsProfile.label)
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            if let executable = graphicsStatus?.executable {
                Text(executable.lastPathComponent).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            Button { model.prepareGame(game) } label: {
                Label(working ? L10n.text("Підготовка компонентів гри…") : L10n.text("Застосувати конфігурацію"),
                      systemImage: "wrench.and.screwdriver")
            }.buttonStyle(PorticoButtonStyle())
                .disabled(working || (usesDirectX9 && graphicsStatus?.executable == nil) || DistributionPolicy.isAppStore || bottle.map { !model.canPrepareGame(in: $0) } != false)
                .accessibilityIdentifier("launch-guide-prepare")
            if usesDirectX9 {
                Button(L10n.text("Завантажити та встановити компоненти DirectX…")) {
                    model.prepareGame(game, installLegacyDirectX: true)
                }.buttonStyle(PorticoButtonStyle())
                    .disabled(working || graphicsStatus?.executable == nil || DistributionPolicy.isAppStore
                        || bottle.map { !model.canPrepareGame(in: $0) } != false)
                    .accessibilityIdentifier("launch-guide-download-directx")
                Text(L10n.text("Microsoft · June 2010 · 100 МБ. У разі помилок D3DX9 або D3DCompiler завершіть встановлення у вікні інсталятора."))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if let progress = model.gamePreparationProgress[game.id] { GamePreparationProgress(progress: progress) }
            Text(L10n.text("Закрийте гру перед налаштуванням графіки. Steam можна залишити відкритим."))
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.mint.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var installationActions: some View {
        HStack(spacing: 10) {
            if isSteam, let bottle {
                if !clientInstalled {
                    Button(L10n.text("Встановити Steam")) {
                        model.sheet = nil; model.section = .steam; model.installSteam(in: bottle)
                    }.buttonStyle(PorticoButtonStyle())
                        .disabled(DistributionPolicy.isAppStore || model.isBusy(bottle) || bottle.status != .ready)
                } else {
                    Button(installed ? L10n.text("Відкрити Steam") : L10n.text("Встановити гру в Steam")) {
                        guard let appID = game.steamAppID else { return }
                        model.sheet = nil; model.section = .steam
                        model.steam(installed ? .library : .install(appID: appID), in: bottle)
                    }.buttonStyle(PorticoButtonStyle()).disabled(!model.canUseSteam(in: bottle))
                        .accessibilityIdentifier("launch-guide-install-game")
                }
            } else if !isCrossOver, let bottle {
                Button(L10n.text("Відкрити інсталятор…")) {
                    model.sheet = nil; model.install(in: bottle)
                }.buttonStyle(PorticoButtonStyle()).disabled(model.isBusy(bottle) || bottle.status != .ready)
            }
            Button(L10n.text("Перевірити знову")) { recheck() }
                .buttonStyle(PorticoButtonStyle()).disabled(working)
                .accessibilityIdentifier("launch-guide-refresh")
        }
    }

    private func check(_ title: String, good: Bool) -> some View {
        Label(title, systemImage: good ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 10)).foregroundStyle(good ? Palette.mint : Palette.amber)
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.mint).frame(width: 25, height: 25)
                .background(Palette.elevated, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
            }
        }
    }

    private func recheck() {
        didCheck = true; checkError = nil; installed = false; clientInstalled = false
        launchFilesValid = false; graphicsStatus = nil
        do {
            if let bottle, let store = model.store {
                let prefix = store.prefixURL(for: bottle)
                clientInstalled = SteamSupport.executable(in: prefix) != nil
                if isSteam {
                    installed = try SteamSupport.installedGames(in: prefix).contains { $0.id == game.steamAppID }
                }
                if !isCrossOver { graphicsStatus = try GameGraphics.inspect(game: game, prefix: prefix) }
            }
            try game.validateLaunchConfiguration()
            launchFilesValid = true
        } catch { checkError = error.localizedDescription }
    }
}

struct GamePreparationProgress: View {
    let progress: InstallProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = progress.fraction { ProgressView(value: fraction) }
            Text(progress.stage == "directx-installer"
                 ? L10n.text("Завершіть встановлення DirectX у вікні інсталятора. Після цього Portico застосує профіль гри.")
                 : progress.stage == "verifying" ? L10n.text("Перевірка завантаження…") : L10n.text("Завантаження компонентів DirectX…"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}
