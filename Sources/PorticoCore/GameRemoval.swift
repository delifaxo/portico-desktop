import Foundation

/// Validates an explicitly selected installation folder before the app moves it to Trash.
/// Steam and CrossOver own their installations and must use their own uninstallers.
public enum GameRemoval {
    public static func validatedFolder(_ folder: URL, for game: Game, in library: Library,
                                       libraryRoot: URL,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        guard game.effectiveLaunchMethod == .executable, game.steamAppID == nil,
              library.games.contains(game), folder.isFileURL else {
            throw PorticoError.invalidInput(L10n.text("Для цієї гри використовуйте видалення у Steam або CrossOver."))
        }
        let selected = folder.standardizedFileURL
        let canonical = selected.resolvingSymlinksInPath()
        let values = try selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              selected.path == canonical.path else {
            throw PorticoError.invalidInput(L10n.text("Виберіть справжню папку гри, а не символічне посилання."))
        }
        let executable = URL(fileURLWithPath: game.executablePath).standardizedFileURL.resolvingSymlinksInPath()
        let executableValues = try executable.resourceValues(forKeys: [.isRegularFileKey])
        guard executableValues.isRegularFile == true, contains(canonical, executable) else {
            throw PorticoError.invalidInput(L10n.text("Вибрана папка має містити виконуваний файл цієї гри."))
        }

        var protected = [libraryRoot, home]
        protected += ["Desktop", "Documents", "Downloads", "Library", "Applications"].map { home.appendingPathComponent($0) }
        protected += ["/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/usr", "/opt", "/bin", "/sbin", "/dev"].map { URL(fileURLWithPath: $0) }
        for bottle in library.bottles {
            let prefix = libraryRoot.appendingPathComponent("Bottles/\(bottle.id.uuidString)")
            protected.append(prefix)
            protected += ["drive_c", "dosdevices", "drive_c/windows", "drive_c/users", "drive_c/ProgramData",
                          "drive_c/Program Files", "drive_c/Program Files (x86)"].map { prefix.appendingPathComponent($0) }
            if bottle.enginePath.hasPrefix("/") { protected.append(URL(fileURLWithPath: bottle.enginePath)) }
        }
        // Case-insensitive names also cover external prefixes and shared game libraries.
        let sharedNames: Set<String> = ["games", "steam", "steamapps", "common", "gog games", "epic games",
                                        "program files", "program files (x86)", "windows", "users", "programdata",
                                        "drive_c", "dosdevices", "bottles"]
        guard !sharedNames.contains(canonical.lastPathComponent.lowercased()),
              !canonical.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") || $0.lowercased().hasSuffix(".framework") }),
              !protected.contains(where: { contains(canonical, $0.standardizedFileURL.resolvingSymlinksInPath()) }) else {
            throw PorticoError.invalidInput(L10n.text("Не можна видаляти спільну папку, середовище Windows або системні файли. Виберіть окрему папку гри."))
        }
        for other in library.games where other.id != game.id {
            let paths = [other.executablePath, other.workingDirectory, other.graphicsExecutablePath,
                         other.crossOverLauncher?.launcherPath].compactMap { $0 }
            if paths.contains(where: { contains(canonical, URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()) }) {
                throw PorticoError.invalidInput(L10n.text("Цю папку використовує гра «\(other.name)». Спочатку виберіть окрему папку або вилучіть зайву картку."))
            }
        }
        for other in library.crossOverGames ?? [] {
            if contains(canonical, URL(fileURLWithPath: other.launcherPath).standardizedFileURL.resolvingSymlinksInPath()) {
                throw PorticoError.invalidInput(L10n.text("Цю папку використовує гра «\(other.name)». Спочатку виберіть окрему папку або вилучіть зайву картку."))
            }
        }
        return canonical
    }

    private static func contains(_ folder: URL, _ item: URL) -> Bool {
        let parent = folder.pathComponents.map { $0.lowercased() }
        let child = item.pathComponents.map { $0.lowercased() }
        return child.starts(with: parent)
    }
}
