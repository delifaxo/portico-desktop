import SwiftUI
import AppKit
import PorticoCore

struct PorticoNavigation: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "door.left.hand.open").foregroundStyle(Palette.mint)
                Text("Portico").font(.system(size: 21, weight: .semibold))
            }.accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            HStack(spacing: 3) {
                ForEach([AppSection.library, .steam, .bottles]) { section in
                    Button { model.section = section } label: {
                        Text(section.title).font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 17).padding(.vertical, 10)
                            .foregroundStyle(model.section == section ? Palette.onAccent : Palette.muted)
                            .background(model.section == section ? Palette.mint : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("nav-\(section.rawValue)")
                }
            }.padding(4).background(Palette.panel, in: Capsule())
            Spacer(minLength: 12)
            LanguagePicker(model: model)
            ThemePicker(model: model)
            Button {
                NotificationCenter.default.post(name: CrashReportText.openNotification, object: nil)
            } label: {
                Label(CrashReportText.text("Репорт", "Report"), systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.system(size: 12, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                .help(CrashReportText.text("Повідомити про збій", "Report a crash"))
                .accessibilityIdentifier("report-open")
            Button { model.section = .settings } label: {
                ViewThatFits(in: .horizontal) {
                    Label(AppSection.settings.title, systemImage: "gearshape").fixedSize()
                    Image(systemName: "gearshape")
                }.font(.system(size: 13, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(model.section == .settings ? Palette.mint : Palette.text)
                .help(AppSection.settings.title).accessibilityLabel(AppSection.settings.title)
                .accessibilityIdentifier("nav-settings")
        }.padding(.horizontal, 36).padding(.top, 15).padding(.bottom, 18)
    }
}

struct PorticoUtilityBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 20) {
            if model.section == .library {
                HStack(spacing: 22) {
                    ForEach(GameFilter.allCases) { filter in
                        Button { model.filter = filter } label: {
                            VStack(spacing: 9) {
                                Text(filter.title).font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(model.filter == filter ? Palette.text : Palette.muted)
                                Capsule().fill(model.filter == filter ? Palette.mint : .clear).frame(height: 2)
                            }.fixedSize(horizontal: true, vertical: false)
                        }.buttonStyle(.plain).accessibilityIdentifier("library-filter-\(filter.rawValue)")
                    }
                }
            } else {
                HStack(spacing: 7) {
                    Circle().fill(model.engineReady ? Palette.mint : Palette.amber).frame(width: 5, height: 5)
                    Text(model.engineReady ? L10n.text("Wine підключено") : L10n.text("Потрібен рушій Wine"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 10)
            if !model.operations.isEmpty {
                ProgressView().controlSize(.small)
                Text(L10n.text("Активних середовищ: \(model.operations.count)"))
                    .font(.system(size: 11)).foregroundStyle(Palette.mint)
            }
            if model.section == .library && !DistributionPolicy.isAppStore {
                Button { model.sheet = .crossOverImport } label: {
                    Label(L10n.text("Імпорт із CrossOver"), systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("crossover-import-open")
            }
            ForEach([AppSection.runtime, .logs, .setup]) { section in
                Button { model.section = section } label: { Label(section.title, systemImage: section.symbol) }
                    .foregroundStyle(model.section == section ? Palette.mint : Palette.muted)
                    .accessibilityIdentifier("nav-\(section.rawValue)")
            }
        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
            .lineLimit(1).padding(.vertical, 7)
    }
}

/// A single selection model covers managed games and imported CrossOver shortcuts.
private enum GalleryGame: Identifiable {
    case managed(Game), crossOver(CrossOverGame)

    var id: String {
        switch self {
        case .managed(let game): return "game-\(game.id)"
        case .crossOver(let game): return "crossover-\(game.id)"
        }
    }
    var game: Game {
        switch self {
        case .managed(let game): return game
        case .crossOver(let game):
            return Game(id: game.id, name: game.name, bottleID: game.id,
                        executablePath: game.launcherPath, launchMethod: .crossOver, crossOverLauncher: game)
        }
    }
    var isFavorite: Bool {
        switch self {
        case .managed(let game): return game.isFavorite
        case .crossOver(let game): return game.isFavorite
        }
    }
    var removalTarget: GameRemovalTarget {
        switch self {
        case .managed(let game): return .game(game)
        case .crossOver(let game): return .crossOver(game)
        }
    }
}

struct GalleryLibraryView: View {
    @ObservedObject var model: AppModel
    private var selectedID: String? { model.selectedGalleryGameID }

    private var games: [GalleryGame] {
        model.filteredGames.map(GalleryGame.managed) + model.filteredCrossOverGames.map(GalleryGame.crossOver)
    }
    private var selected: GalleryGame? { games.first { $0.id == selectedID } ?? games.first }

    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width >= 1580 ? 5 : geometry.size.width >= 1200 ? 4 : 3
            let coverHeight = max(175, min(250, geometry.size.height - 335))
            VStack(spacing: 17) {
                header
                PorticoUtilityBar(model: model)
                ScrollView {
                    if model.totalGameCount == 0 {
                        emptyLibrary.frame(minHeight: coverHeight)
                    } else if games.isEmpty {
                        VStack(spacing: 13) {
                            Image(systemName: "magnifyingglass").font(.system(size: 32, weight: .light))
                            Text(L10n.text("Ігор не знайдено")).font(.system(size: 19, weight: .medium))
                            Text(L10n.text("Змініть запит або виберіть інший фільтр."))
                                .font(.system(size: 13)).foregroundStyle(Palette.muted)
                        }.frame(maxWidth: .infinity, minHeight: coverHeight)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 30, alignment: .top), count: columns),
                                  alignment: .leading, spacing: 27) {
                            ForEach(games) { item in card(item, height: coverHeight) }
                        }.padding(.horizontal, 4).padding(.top, 5).padding(.bottom, 18)
                    }
                }.scrollIndicators(.hidden)
                if let selected { launchBar(selected) }
            }.padding(.horizontal, 36).padding(.top, 15).padding(.bottom, 22)
        }
        .onChange(of: games.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? "") { model.selectedGalleryGameID = ids.first }
        }
    }

    private var header: some View {
        HStack(spacing: 17) {
            Text(L10n.text("Ваша бібліотека")).font(.system(size: 32, weight: .semibold)).tracking(-0.9)
            Text(L10n.text("Ігор: \(model.totalGameCount)"))
                .font(.system(size: 13)).foregroundStyle(Palette.muted)
            Spacer(minLength: 15)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField(L10n.text("Знайти гру"), text: $model.search)
                    .textFieldStyle(.plain).accessibilityIdentifier("library-search")
            }.font(.system(size: 13)).padding(12).frame(width: 195)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            Button {
                if model.readyBottles.isEmpty { model.section = .setup }
                else { model.sheet = .addGame }
            } label: { Label(L10n.text("Додати гру"), systemImage: "plus") }
                .buttonStyle(PorticoButtonStyle()).accessibilityIdentifier("library-add-game")
        }.padding(.bottom, 3)
    }

    private func card(_ item: GalleryGame, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.selectedGalleryGameID = item.id } label: {
                GamePlaceholder().frame(height: height)
                    .overlay(alignment: .topTrailing) {
                        if item.isFavorite {
                            Image(systemName: "heart.fill").font(.system(size: 14))
                                .foregroundStyle(Palette.mint).padding(17)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(selected?.id == item.id ? Palette.mint : Palette.separator.opacity(0.5),
                                      lineWidth: selected?.id == item.id ? 2.5 : 1))
                    .padding(3)
            }.buttonStyle(.plain).accessibilityLabel(item.game.name)
                .accessibilityValue(selected?.id == item.id ? L10n.text("Вибрано") : "")
                .accessibilityIdentifier("game-select-\(item.game.id.uuidString)")
            HStack(alignment: .top, spacing: 9) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.game.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        .help(item.game.name)
                    Text(source(item)).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu { actions(item) } label: {
                    Image(systemName: "ellipsis").frame(width: 29, height: 24)
                        .background(Palette.panel, in: Capsule())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(L10n.text("Дії з грою"))
                    .accessibilityIdentifier("game-actions-\(item.game.id.uuidString)")
            }.padding(.horizontal, 10)
        }.contextMenu { actions(item) }
    }

    private func launchBar(_ item: GalleryGame) -> some View {
        HStack(spacing: 18) {
            GamePlaceholder(compact: true).frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.game.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(source(item)).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { toggleFavorite(item) } label: {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart").font(.system(size: 17))
            }.buttonStyle(.plain).foregroundStyle(item.isFavorite ? Palette.mint : Palette.muted)
                .help(item.isFavorite ? L10n.text("Вилучити з обраного") : L10n.text("До обраного"))
                .accessibilityLabel(item.isFavorite ? L10n.text("Вилучити з обраного") : L10n.text("До обраного"))
                .accessibilityIdentifier("game-favorite-\(item.game.id.uuidString)")
            if case .managed(let game) = item {
                Button { model.sheet = .editGame(game.id) } label: {
                    Label(L10n.text("Редагувати"), systemImage: "pencil")
                }.buttonStyle(PorticoButtonStyle()).accessibilityIdentifier("game-settings-\(game.id.uuidString)")
                Button { model.sheet = .gameParameters(game.id) } label: {
                    Label(L10n.text("Параметри"), systemImage: "slider.horizontal.3")
                }.buttonStyle(PorticoButtonStyle()).accessibilityIdentifier("game-parameters-\(game.id.uuidString)")
            } else {
                Button { reveal(item) } label: { Label("Finder", systemImage: "folder") }
                    .buttonStyle(PorticoButtonStyle()).help(L10n.text("Показати файл у Finder"))
            }
            if model.runningGames[item.game.id] != nil, let bottle = model.bottle(for: item.game) {
                Button { model.stop(bottle) } label: { Label(L10n.text("Зупинити"), systemImage: "stop.fill") }
                    .buttonStyle(PorticoButtonStyle(primary: true))
                    .disabled(model.isStopping(bottle)).accessibilityIdentifier("game-stop-\(item.game.id.uuidString)")
            } else {
                Button { model.launch(item.game) } label: {
                    Label(L10n.text("Грати"), systemImage: "play.fill").frame(minWidth: 83)
                }.buttonStyle(PorticoButtonStyle(primary: true))
                    .disabled(model.removingGames.contains(item.game.id) || model.preparingGames.contains(item.game.id)
                              || model.crossOverLaunchRequests.contains(item.game.id))
                    .accessibilityIdentifier("game-play-\(item.game.id.uuidString)")
            }
        }.padding(17).background(Palette.panel, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).stroke(Palette.separator.opacity(0.7), lineWidth: 1))
            .shadow(color: .black.opacity(model.theme == .dark ? 0.08 : 0.04), radius: 16, y: 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("selected-game-launch-bar")
    }

    @ViewBuilder private func actions(_ item: GalleryGame) -> some View {
        Button(L10n.text("Грати")) { model.launch(item.game) }
        if case .managed(let game) = item {
            Button(L10n.text("Налаштування гри…")) { model.sheet = .editGame(game.id) }
            if let bottle = model.bottle(for: game) {
                Button(L10n.text("Журнал запуску")) { model.showLog(bottle) }
            }
        }
        Button(item.isFavorite ? L10n.text("Вилучити з обраного") : L10n.text("До обраного")) { toggleFavorite(item) }
        Button(L10n.text("Показати файл у Finder")) { reveal(item) }
        Divider()
        Button(L10n.text("Видалити гру…"), role: .destructive) { model.sheet = .removeGame(item.removalTarget) }
            .disabled(!model.canRemove(item.removalTarget))
            .accessibilityIdentifier("game-delete-\(item.game.id.uuidString)")
    }

    private func source(_ item: GalleryGame) -> String {
        let game = item.game
        if game.effectiveLaunchMethod == .crossOver { return "CrossOver · \(game.crossOverLauncher?.bottleName ?? "Windows")" }
        if game.effectiveLaunchMethod == .steam { return L10n.text("Steam · Windows") }
        return model.bottle(for: game)?.name ?? L10n.text("Середовище недоступне")
    }

    private func toggleFavorite(_ item: GalleryGame) {
        switch item {
        case .managed(let game): model.toggleFavorite(game)
        case .crossOver(let game): model.toggleCrossOverFavorite(game)
        }
    }

    private func reveal(_ item: GalleryGame) {
        let game = item.game
        let path = game.effectiveLaunchMethod == .crossOver ? game.crossOverLauncher?.launcherPath ?? game.executablePath
            : game.effectiveLaunchMethod == .steam ? game.workingDirectory ?? game.executablePath : game.executablePath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private var emptyLibrary: some View {
        VStack(spacing: 17) {
            Image(systemName: "gamecontroller").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(Palette.mint)
            Text(L10n.text("Тут буде ваша перша гра")).font(.system(size: 22, weight: .medium))
            Text(L10n.text("Почніть із Wine та окремого середовища.\nПотім установіть гру або додайте готовий .exe."))
                .font(.system(size: 13)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(4)
            Button { model.section = .setup } label: {
                Label(L10n.text("Почати налаштування"), systemImage: "plus")
            }.buttonStyle(PorticoButtonStyle(primary: true))
        }.frame(maxWidth: .infinity).padding(35)
    }
}

/// A shared native placeholder keeps large libraries consistent without cover downloads.
private struct GamePlaceholder: View {
    var compact = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.artwork, Palette.artworkEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
            if !compact {
                RoundedRectangle(cornerRadius: 38).stroke(Palette.mint.opacity(0.06), lineWidth: 1)
                    .frame(width: 198, height: 198).rotationEffect(.degrees(-12))
                RoundedRectangle(cornerRadius: 30).stroke(Palette.mint.opacity(0.10), lineWidth: 1)
                    .frame(width: 155, height: 155).rotationEffect(.degrees(12))
            }
            Image(systemName: "gamecontroller")
                .font(.system(size: compact ? 27 : 61, weight: .ultraLight))
                .foregroundStyle(Palette.mint.opacity(compact ? 0.75 : 0.65))
        }.accessibilityHidden(true)
    }
}
