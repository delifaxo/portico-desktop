import SwiftUI
import AppKit
import PorticoCore

enum GameRemovalTarget {
    case game(Game)
    case crossOver(CrossOverGame)

    var id: UUID {
        switch self { case .game(let game): return game.id; case .crossOver(let game): return game.id }
    }
    var name: String {
        switch self { case .game(let game): return game.name; case .crossOver(let game): return game.name }
    }
    var crossOver: CrossOverGame? {
        switch self { case .game(let game): return game.effectiveLaunchMethod == .crossOver ? game.crossOverLauncher : nil
        case .crossOver(let game): return game }
    }
    var steamGame: Game? {
        if case .game(let game) = self, game.effectiveLaunchMethod != .crossOver, game.steamAppID != nil { return game }
        return nil
    }
}

@MainActor
extension AppModel {
    func canRemove(_ target: GameRemovalTarget, files: Bool = false) -> Bool {
        guard store != nil, storageProblem == nil, !removingGames.contains(target.id),
              runningGames[target.id] == nil, !preparingGames.contains(target.id),
              !crossOverLaunchRequests.contains(target.id) else { return false }
        if case .game(let game) = target {
            guard library.games.contains(where: { $0.id == game.id }) else { return false }
            if let bottle = bottle(for: game) {
                if isStopping(bottle) || steamStarting.contains(bottle.id) || steamCommands.contains(bottle.id) { return false }
                if isBusy(bottle) && !(game.steamAppID != nil && steamSessions.contains(bottle.id)) { return false }
                if files && target.steamGame != nil { return canUseSteam(in: bottle) }
                if files && target.crossOver == nil { return !isBusy(bottle) }
            } else if files && target.crossOver == nil { return false }
        } else if !crossOverGames.contains(where: { $0.id == target.id }) { return false }
        return true
    }

    @discardableResult
    func removeLibraryEntry(_ target: GameRemovalTarget) -> Bool {
        guard canRemove(target) else { return false }
        var next = library
        switch target {
        case .game(let game): next.games.removeAll { $0.id == game.id }
        case .crossOver(let game): next.crossOverGames?.removeAll { $0.id == game.id }
        }
        guard commit(next) else { return false }
        preparedGames.remove(target.id)
        gamePreparationErrors[target.id] = nil
        gamePreparationProgress[target.id] = nil
        crossOverRequestedGames.remove(target.id)
        sheet = nil
        return true
    }

    func trashGameFolder(_ folder: URL, for game: Game) async throws {
        let target = GameRemovalTarget.game(game)
        guard canRemove(target, files: true), let store, let bottle = bottle(for: game),
              let current = library.games.first(where: { $0.id == game.id }), current == game else { throw PorticoError.busy }
        let validated = try GameRemoval.validatedFolder(folder, for: current, in: library, libraryRoot: store.rootURL)
        // Verify that the metadata can be persisted before touching the selected folder.
        try store.save(library)
        removingGames.insert(game.id)
        operations[bottle.id] = "Видалення гри…"
        defer { removingGames.remove(game.id); operations[bottle.id] = nil }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([validated]) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        // Publish removal only after the filesystem operation succeeds. A failed save
        // retains the card and reports the error; the folder remains recoverable in Trash.
        var next = library
        next.games.removeAll { $0.id == game.id }
        guard commit(next) else { return }
        preparedGames.remove(game.id)
        gamePreparationErrors[game.id] = nil
        gamePreparationProgress[game.id] = nil
        sheet = nil
    }
}

struct GameRemovalSheet: View {
    @ObservedObject var model: AppModel
    let target: GameRemovalTarget
    @State private var deleteFiles = false
    @State private var folder: URL?
    @State private var error: String?
    @State private var working = false
    @State private var steamDirectory: URL?

    private var available: Bool { model.canRemove(target, files: deleteFiles) }
    private var confirmTitle: String {
        if !deleteFiles { return L10n.text("Вилучити з бібліотеки") }
        if target.crossOver != nil { return L10n.text("Відкрити CrossOver") }
        if target.steamGame != nil { return L10n.text("Видалити через Steam") }
        return L10n.text("Перемістити в Кошик")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L10n.text("Видалити гру"), systemImage: "trash").font(.system(size: 23, weight: .semibold))
            Text(target.name).font(.system(size: 16, weight: .medium)).textSelection(.enabled)
            Picker(L10n.text("Спосіб видалення"), selection: $deleteFiles) {
                Text(L10n.text("Лише з бібліотеки")).tag(false)
                Text(L10n.text("Видалити з диска")).tag(true)
            }.pickerStyle(.radioGroup).disabled(working || steamDirectory != nil)
                .accessibilityIdentifier("game-removal-mode")
            if !deleteFiles {
                Text(L10n.text("Картку буде вилучено з Portico. Файли гри та збереження залишаться на диску; гру можна додати знову."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else if let crossOver = target.crossOver {
                Text(L10n.text("У CrossOver виберіть середовище «\(crossOver.bottleName)» і видаліть гру зі списку встановлених програм. Після завершення вилучіть її картку з Portico."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else if target.steamGame != nil {
                Text(L10n.text("Підтвердьте видалення у Windows-клієнті Steam цього середовища. Картка зникне після перевірки, що Steam видалив папку гри. Скасування у Steam збереже картку."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                if steamDirectory != nil {
                    Label(L10n.text("Очікуємо видалення у Steam…"), systemImage: "clock").foregroundStyle(Palette.mint)
                }
            } else {
                Text(L10n.text("Виберіть окрему папку встановленої гри. Увесь її вміст, включно зі збереженнями всередині, буде переміщено в Кошик. Збереження поза цією папкою залишаться. Для звільнення місця очистіть Кошик."))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Button { chooseFolder() } label: {
                    Label(folder == nil ? L10n.text("Вибрати папку гри…") : L10n.text("Змінити папку…"), systemImage: "folder")
                }.buttonStyle(PorticoButtonStyle()).disabled(working)
                    .accessibilityIdentifier("game-removal-choose-folder")
                if let folder {
                    Text(folder.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if !available {
                Text(L10n.text("Дочекайтеся завершення операцій і зупиніть гру перед видаленням."))
                    .font(.system(size: 12)).foregroundStyle(Palette.amber)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.amber).textSelection(.enabled) }
            Divider()
            HStack {
                Button(L10n.text("Скасувати")) { model.sheet = nil }
                    .buttonStyle(PorticoButtonStyle()).keyboardShortcut(.cancelAction).disabled(working)
                    .accessibilityIdentifier("game-removal-cancel")
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(confirmTitle, role: .destructive) { confirm() }
                    .buttonStyle(PorticoButtonStyle())
                    .disabled(!available || working || steamDirectory != nil || deleteFiles && target.crossOver == nil && target.steamGame == nil && folder == nil)
                    .accessibilityIdentifier("game-removal-confirm")
            }
        }.padding(28).frame(width: 590).fixedSize(horizontal: false, vertical: true).background(Palette.background)
            .interactiveDismissDisabled(working)
            .onChange(of: deleteFiles) { _, _ in error = nil }
            .task(id: steamDirectory) {
                guard let directory = steamDirectory, let game = target.steamGame, let bottle = model.bottle(for: game) else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    if FileManager.default.fileExists(atPath: directory.path) {
                        if !model.steamSessions.contains(bottle.id) && !model.steamCommands.contains(bottle.id) {
                            steamDirectory = nil
                            error = L10n.text("Steam закрито, але файли гри залишилися. Можна повторити видалення або скасувати дію.")
                            return
                        }
                        continue
                    }
                    model.refreshSteam(in: bottle)
                    guard model.steamScanErrors[bottle.id] == nil,
                          !(model.steamInstalledGames[bottle.id] ?? []).contains(where: { $0.id == game.steamAppID }) else { continue }
                    if model.removeLibraryEntry(target) { return }
                }
            }
    }

    private func chooseFolder() {
        guard case .game(let game) = target, let store = model.store else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Вибрати папку гри…")
        panel.message = L10n.text("Виберіть лише папку цієї гри. Увесь її вміст буде переміщено в Кошик.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: game.executablePath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            folder = try GameRemoval.validatedFolder(selected, for: game, in: model.library, libraryRoot: store.rootURL)
            error = nil
        } catch { folder = nil; self.error = error.localizedDescription }
    }

    private func confirm() {
        error = nil
        guard available else { return }
        if !deleteFiles { model.removeLibraryEntry(target); return }
        if target.crossOver != nil {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeweavers.CrossOver") else {
                error = L10n.text("CrossOver не знайдено. Відкрийте встановлений CrossOver вручну."); return
            }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, problem in
                if let problem { Task { @MainActor in model.show(problem) } }
            }
        } else if let game = target.steamGame, let bottle = model.bottle(for: game), let appID = game.steamAppID {
            model.refreshSteam(in: bottle)
            guard model.steamScanErrors[bottle.id] == nil,
                  let installed = model.steamInstalledGames[bottle.id]?.first(where: { $0.id == appID }) else {
                error = L10n.text("Гру не знайдено серед встановлених у цьому Steam. Можна вилучити лише картку з бібліотеки."); return
            }
            steamDirectory = installed.installDirectory
            model.steam(.uninstall(appID: appID), in: bottle)
        } else if case .game(let game) = target, let folder {
            working = true
            Task {
                defer { working = false }
                do { try await model.trashGameFolder(folder, for: game) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
