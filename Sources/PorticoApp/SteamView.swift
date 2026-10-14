import SwiftUI
import PorticoCore

struct SteamView: View {
    @ObservedObject var model: AppModel
    @State private var bottleID: UUID?
    @State private var appID = ""

    private var selectedBottle: Bottle? {
        model.readyBottles.first { $0.id == bottleID }
            ?? model.readyBottles.first { $0.steamDesktop == true && $0.graphics?.backend == .d3dMetal }
            ?? model.readyBottles.first { $0.steamDesktop == true }
            ?? model.readyBottles.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("Steam для Windows")).font(.system(size: 29, weight: .semibold)).tracking(-0.8)
                    Text(L10n.text("Встановіть клієнт, увійдіть у Steam і завантажуйте ігри для Windows у вибране середовище."))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                }
                Spacer(minLength: 15)
                Button { model.openURL("https://store.steampowered.com/about/") } label: {
                    Label(L10n.text("Про Steam"), systemImage: "arrow.up.right")
                }.buttonStyle(PorticoButtonStyle())
            }

            if let bottle = selectedBottle {
                HStack(spacing: 14) {
                    Image(systemName: "shippingbox").foregroundStyle(Palette.mint)
                    Picker(L10n.text("Середовище"), selection: $bottleID) {
                        ForEach(model.readyBottles) { item in Text(item.name).tag(Optional(item.id)) }
                    }.frame(maxWidth: 360)
                    Spacer()
                    Button { model.refreshSteam(in: bottle) } label: {
                        Label(L10n.text("Оновити"), systemImage: "arrow.clockwise")
                    }.buttonStyle(PorticoButtonStyle())
                }
                clientCard(bottle)
                installedGamesCard(bottle)
            } else {
                VStack(alignment: .leading, spacing: 17) {
                    Image(systemName: "shippingbox").font(.system(size: 31, weight: .light)).foregroundStyle(Palette.mint)
                    Text(L10n.text("Спочатку підготуйте середовище")).font(.system(size: 20, weight: .semibold))
                    Text(L10n.text("Steam і завантажені ігри зберігатимуться на окремому диску C: всередині середовища Portico."))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                    if model.library.bottles.contains(where: { $0.status == .creating }) {
                        Button { model.section = .bottles } label: {
                            Label(L10n.text("Перевірити підготовку"), systemImage: "arrow.right")
                        }.buttonStyle(PorticoButtonStyle(primary: true))
                    } else {
                        Button { model.sheet = model.engineReady ? .createBottle : .runtimeSetup } label: {
                            Label(L10n.text(model.engineReady ? "Створити середовище" : "Підключити Wine"), systemImage: "plus")
                        }.buttonStyle(PorticoButtonStyle(primary: true))
                    }
                }.padding(27).frame(maxWidth: .infinity, alignment: .leading).steamPanel()
            }

            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.text("Ігри встановлюються в офіційному клієнті"), systemImage: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.text("Вхід, Steam Guard, покупки та перебіг завантажень доступні у вікні Steam. Portico не запитує пароль і не зберігає дані вашого облікового запису."))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                Text(L10n.text("Завантаження версії для Windows не гарантує запуск: сумісність DirectX і античита залежить від гри та вибраного Wine."))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.padding(22).steamPanel()
        }
        .task(id: selectedBottle?.id) {
            guard let bottle = selectedBottle else { return }
            bottleID = bottle.id
            while !Task.isCancelled {
                model.refreshSteam(in: bottle)
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func clientCard(_ bottle: Bottle) -> some View {
        let installed = model.steamClients[bottle.id] != nil
        let active = model.steamSessions.contains(bottle.id)
        let busy = model.isBusy(bottle)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 15) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 30, weight: .light))
                    .foregroundStyle(Palette.mint).frame(width: 62, height: 62)
                    .background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Steam").font(.system(size: 24, weight: .semibold))
                    Text(L10n.text(active ? "Клієнт працює" : installed ? "Клієнт встановлено" : "Клієнт ще не встановлено"))
                        .font(.system(size: 12)).foregroundStyle(installed ? Palette.mint : Palette.muted)
                }
                Spacer()
                Text("WINDOWS").font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.2).foregroundStyle(Palette.muted)
            }

            if model.isUISimulation {
                Text(L10n.text("Це тестова копія Portico із симулятором Wine. Вона не запускає інсталятори для Windows. Відкрийте звичайний застосунок Portico й підключіть робочий Wine."))
                    .font(.system(size: 12)).foregroundStyle(Palette.amber).lineSpacing(5)
            } else if installed {
                if bottle.steamDesktop == true {
                    Text(L10n.text("Вікно Steam: режим сумісності"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                HStack(spacing: 10) {
                    Button { model.steam(.library, in: bottle) } label: {
                        Label(L10n.text("Відкрити Steam"), systemImage: "play.fill")
                    }.buttonStyle(PorticoButtonStyle(primary: true))
                    Button { model.steam(.store, in: bottle) } label: {
                        Label(L10n.text("Магазин"), systemImage: "bag")
                    }.buttonStyle(PorticoButtonStyle())
                    Button { model.steam(.downloads, in: bottle) } label: {
                        Label(L10n.text("Завантаження"), systemImage: "arrow.down.circle")
                    }.buttonStyle(PorticoButtonStyle())
                    Spacer(minLength: 0)
                }.disabled(!model.canUseSteam(in: bottle))

                DisclosureGroup(L10n.text("Встановити гру за App ID")) {
                    HStack(spacing: 10) {
                        TextField(L10n.text("Наприклад, 435150"), text: $appID).textFieldStyle(.roundedBorder).frame(maxWidth: 230)
                        Button(L10n.text("Встановити в Steam")) { model.steam(.install(appID: appID), in: bottle) }
                            .buttonStyle(PorticoButtonStyle())
                            .disabled(!model.canUseSteam(in: bottle) || (try? SteamAction.validatedAppID(appID)) == nil)
                        Spacer(minLength: 0)
                    }.padding(.top, 10)
                }.font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else if DistributionPolicy.isAppStore {
                Text(L10n.text("Встановлення зовнішнього клієнта Steam недоступне в цій збірці застосунку."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5)
            } else {
                Text(L10n.text("Portico завантажить офіційний інсталятор Steam для Windows. У вікні, що відкриється, завершіть встановлення в стандартну папку."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5)
                Button { model.installSteam(in: bottle) } label: {
                    Label(L10n.text("Встановити Steam"), systemImage: "arrow.down.circle")
                }.buttonStyle(PorticoButtonStyle(primary: true)).disabled(busy)
            }

            if let operation = model.operations[bottle.id] {
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    if active {
                        Circle().fill(Palette.mint).frame(width: 6, height: 6)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(L10n.text(operation)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer(minLength: 0)
                    Button { model.stop(bottle) } label: {
                        Label(L10n.text(model.steamInstallerDownloads.contains(bottle.id) ? "Скасувати завантаження" : "Зупинити"), systemImage: "stop.fill")
                    }.buttonStyle(PorticoButtonStyle())
                }
                if active {
                    Text(L10n.text("Зупинка середовища закриє Steam, запущені ігри та перерве завантаження."))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                } else if installed {
                    Text(L10n.text("Якщо інсталятор сам відкрив Steam, користуйтеся його вікном. Кнопки Portico стануть доступними після закриття клієнта й інсталятора."))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
                }
            }

            if let message = model.steamMessages[bottle.id] {
                Text(L10n.text(message)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4).textSelection(.enabled)
            }
        }.padding(26)
            .background(LinearGradient(colors: [Color(hex: 0x20333C), Palette.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.075)))
    }

    private func installedGamesCard(_ bottle: Bottle) -> some View {
        let games = model.steamInstalledGames[bottle.id] ?? []
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Встановлені ігри Steam")).font(.system(size: 18, weight: .semibold))
                    Text(L10n.text("Після завантаження додайте ігри до спільної бібліотеки Portico."))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { model.importSteamGames(from: bottle) } label: {
                    Label(L10n.text("Додати до Portico"), systemImage: "plus")
                }.buttonStyle(PorticoButtonStyle()).disabled(games.isEmpty || model.steamScanErrors[bottle.id] != nil)
            }
            if let error = model.steamScanErrors[bottle.id] {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber).textSelection(.enabled)
            } else if games.isEmpty {
                Text(L10n.text("Встановлених ігор поки немає. Відкрийте бібліотеку Steam, виберіть гру й натисніть «Встановити». Список оновиться після завершення завантаження."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5).padding(.vertical, 14)
            } else {
                ForEach(games) { game in
                    let imported = model.library.games.first { $0.bottleID == bottle.id && $0.steamAppID == game.id }
                    HStack(spacing: 13) {
                        Image(systemName: "gamecontroller").font(.system(size: 19)).foregroundStyle(Palette.mint)
                            .frame(width: 40, height: 40).background(Palette.elevated, in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(game.name).font(.system(size: 12, weight: .medium))
                            Text("App ID \(game.id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        if imported != nil {
                            Label(L10n.text("У бібліотеці"), systemImage: "checkmark").font(.system(size: 10)).foregroundStyle(Palette.mint)
                        }
                        Button {
                            model.requestSteamLaunch(game, in: bottle)
                        } label: { Label(L10n.text("Грати"), systemImage: "play.fill") }
                            .buttonStyle(PorticoButtonStyle())
                            .accessibilityIdentifier("steam-game-play-\(game.id)")
                    }.padding(.vertical, 4)
                }
            }
        }.padding(24).steamPanel()
    }
}

private extension View {
    func steamPanel() -> some View {
        background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.06)))
    }
}
