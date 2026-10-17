import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PorticoCore

/// Strings are kept together so the optional integration follows the saved UI language.
func cxText(_ ukrainian: String, _ english: String) -> String {
    AppLanguage.saved() == .english ? english : ukrainian
}

@MainActor
extension AppModel {
    var crossOverGames: [CrossOverGame] { library.crossOverGames ?? [] }
    var totalGameCount: Int { library.games.count + crossOverGames.count }
    var filteredCrossOverGames: [CrossOverGame] {
        crossOverGames.filter {
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) &&
            (filter != .favorites || $0.isFavorite) &&
            (filter != .recent || $0.lastPlayedAt != nil)
        }.sorted {
            filter == .recent
                ? ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
                : $0.addedAt > $1.addedAt
        }
    }

    func importCrossOverGame(_ game: CrossOverGame) {
        do {
            let url = try CrossOverSupport.launchURL(for: game)
            var next = library
            var games = next.crossOverGames ?? []
            if !games.contains(where: { URL(fileURLWithPath: $0.launcherPath).standardizedFileURL.resolvingSymlinksInPath() == url }) {
                games.append(game)
            }
            next.crossOverGames = games
            if commit(next) { sheet = nil; section = .library; filter = .all; search = "" }
        } catch { show(error) }
    }

    func removeCrossOverGame(_ game: CrossOverGame) {
        sheet = .removeGame(.crossOver(game))
    }

    func toggleCrossOverFavorite(_ game: CrossOverGame) {
        var next = library
        guard let i = next.crossOverGames?.firstIndex(where: { $0.id == game.id }) else { return }
        next.crossOverGames?[i].isFavorite.toggle()
        commit(next)
    }

    func launchCrossOverGame(_ game: CrossOverGame, libraryGameID: UUID? = nil) {
        let requestID = libraryGameID ?? game.id
        guard !crossOverLaunchRequests.contains(requestID) else { return }
        do {
            // LaunchServices opens CrossOver's helper. Portico never executes the
            // command in its plist or starts standalone Wine on an external bottle.
            let url = try CrossOverSupport.launchURL(for: game)
            crossOverLaunchRequests.insert(requestID)
            crossOverRequestedGames.remove(requestID)
            Task {
                defer { crossOverLaunchRequests.remove(requestID) }
                do {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.environment = FPSCounter.applying(enabled: library.settings.showFPS, to: [:])
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                    crossOverRequestedGames.insert(requestID)
                    var next = library
                    if let libraryGameID, let i = next.games.firstIndex(where: { $0.id == libraryGameID }) {
                        next.games[i].lastPlayedAt = Date()
                        commit(next)
                    } else if let i = next.crossOverGames?.firstIndex(where: { $0.id == game.id }) {
                        next.crossOverGames?[i].lastPlayedAt = Date()
                        commit(next)
                    }
                } catch { show(error) }
            }
        } catch { show(error) }
    }
}

struct CrossOverGameCard: View {
    @ObservedObject var model: AppModel
    let game: CrossOverGame

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 26)).foregroundStyle(Palette.mint)
                Spacer()
                Button(role: .destructive) { model.removeCrossOverGame(game) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help(L10n.text("Видалити гру")).accessibilityLabel(L10n.text("Видалити гру"))
                    .accessibilityIdentifier("game-delete-\(game.id.uuidString)")
                    .disabled(!model.canRemove(.crossOver(game)))
                Button { model.toggleCrossOverFavorite(game) } label: {
                    Image(systemName: game.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(game.isFavorite ? Palette.amber : Palette.muted)
                }.buttonStyle(.plain)
                    .help(game.isFavorite ? L10n.text("Вилучити з обраного") : L10n.text("До обраного"))
            }
            Text(game.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            Text("CrossOver · \(game.bottleName)").font(.system(size: 11)).foregroundStyle(Palette.mint)
            Text(cxText("Використовує встановлену гру та рушій CrossOver.", "Uses the installed game and CrossOver engine."))
                .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3)
            if model.crossOverRequestedGames.contains(game.id) {
                Text(cxText("Запит передано в CrossOver. Завершуйте гру в її вікні.", "Request sent to CrossOver. Quit the game from its own window."))
                    .font(.system(size: 10)).foregroundStyle(Palette.mint)
            }
            Button {
                model.launch(Game(id: game.id, name: game.name, bottleID: game.id,
                    executablePath: game.launcherPath, launchMethod: .crossOver, crossOverLauncher: game))
            } label: {
                Label(model.crossOverLaunchRequests.contains(game.id)
                      ? cxText("Відкриваємо…", "Opening…")
                      : cxText("Запустити", "Play"), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(PorticoButtonStyle(primary: true))
                .disabled(DistributionPolicy.isAppStore || model.crossOverLaunchRequests.contains(game.id))
                .accessibilityIdentifier("crossover-launch-\(game.name)")
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.separator))
            .contextMenu {
                Button(L10n.text("Показати файл у Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.launcherPath)])
                }
                Button(L10n.text("Видалити гру…"), role: .destructive) { model.removeCrossOverGame(game) }
                    .disabled(!model.canRemove(.crossOver(game)))
            }
    }
}

struct CrossOverImportSheet: View {
    @ObservedObject var model: AppModel
    @State private var candidates: [CrossOverGame] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(cxText("Додати з CrossOver", "Add from CrossOver"), systemImage: "arrow.up.forward.app")
                .font(.system(size: 23, weight: .semibold))
            Text(cxText("Ігри запускаються через встановлений CrossOver з поточними налаштуваннями та збереженнями. Повторно завантажувати файли гри не потрібно.",
                        "Games launch through your installed CrossOver with their existing settings and saves. Game files do not need to be downloaded again."))
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if candidates.isEmpty {
                        Text(cxText("Ярлики не знайдено в ~/Applications/CrossOver. Виберіть ярлик гри (.app), створений CrossOver.",
                                    "No shortcuts found in ~/Applications/CrossOver. Choose a game shortcut (.app) created by CrossOver."))
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    ForEach(candidates) { game in
                        HStack(spacing: 14) {
                            Image(systemName: "gamecontroller").foregroundStyle(Palette.mint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.name).font(.system(size: 13, weight: .medium))
                                Text("CrossOver · \(game.bottleName)").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            let imported = model.crossOverGames.contains { $0.launcherPath == game.launcherPath }
                            Button(imported ? cxText("Додано", "Added") : cxText("Додати", "Add")) {
                                model.importCrossOverGame(game)
                            }.buttonStyle(PorticoButtonStyle(primary: !imported)).disabled(imported)
                                .accessibilityIdentifier("crossover-import-\(game.name)")
                        }.padding(13).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(minHeight: 180, maxHeight: 340)
            HStack {
                Button(cxText("Вибрати ярлик…", "Choose shortcut…")) { chooseShortcut() }
                    .buttonStyle(PorticoButtonStyle()).disabled(DistributionPolicy.isAppStore)
                Button(cxText("Оновити", "Refresh")) { candidates = CrossOverSupport.discoverGames() }
                    .buttonStyle(PorticoButtonStyle())
                Spacer()
                Button(cxText("Закрити", "Close")) { model.sheet = nil }
                    .buttonStyle(PorticoButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 620).background(Palette.sidebar)
            .onAppear { candidates = CrossOverSupport.discoverGames() }
    }

    private func chooseShortcut() {
        let panel = NSOpenPanel()
        panel.title = cxText("Виберіть ярлик CrossOver (.app)", "Choose a CrossOver shortcut (.app)")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CrossOver")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { model.importCrossOverGame(try CrossOverSupport.game(at: url)) }
        catch { model.show(error) }
    }
}
