import Foundation

/// References an existing CrossOver launcher; Portico does not own its bottle or game files.
public struct CrossOverGame: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var launcherPath: String
    public var bottleName: String
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var isFavorite: Bool

    public init(id: UUID = UUID(), name: String, launcherPath: String, bottleName: String,
                addedAt: Date = Date(), lastPlayedAt: Date? = nil, isFavorite: Bool = false) {
        self.id = id; self.name = name; self.launcherPath = launcherPath
        self.bottleName = bottleName; self.addedAt = addedAt; self.lastPlayedAt = lastPlayedAt
        self.isFavorite = isFavorite
    }
}

/// Reads CrossOver's generated Menu Helper apps. Their commands remain opaque and are
/// never evaluated by Portico; the app layer opens the validated bundle with macOS.
public enum CrossOverSupport {
    public static var defaultLaunchersURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/CrossOver", isDirectory: true)
    }

    public static func discoverGames(in root: URL? = nil) -> [CrossOverGame] {
        guard !DistributionPolicy.isAppStore else { return [] }
        let root = root ?? defaultLaunchersURL
        guard root.isFileURL,
              let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var games: [CrossOverGame] = []
        var paths: Set<String> = []
        for case let candidate as URL in enumerator {
            guard candidate.pathExtension.lowercased() == "app" else { continue }
            enumerator.skipDescendants()
            if let game = try? game(at: candidate), paths.insert(game.launcherPath).inserted {
                games.append(game)
            }
        }
        return games.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.launcherPath < $1.launcherPath : comparison == .orderedAscending
        }
    }

    public static func game(at launcher: URL) throws -> CrossOverGame {
        try requireAvailable()
        guard launcher.isFileURL, launcher.path.hasPrefix("/"),
              launcher.pathExtension.lowercased() == "app" else { throw invalidLauncher() }
        let bundle = launcher.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundle.path, isDirectory: &directory), directory.boolValue else {
            throw invalidLauncher()
        }
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Menu Helper")
        guard let attributes = try? info.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              attributes.isRegularFile == true, let size = attributes.fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: info),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              identifier.hasPrefix("com.codeweavers.CrossOverHelper."),
              plist["CFBundleExecutable"] as? String == "Menu Helper",
              let bottleName = plist["CXHelperAppBottleName"] as? String, validName(bottleName),
              let command = plist["CrossOverHelperCommand"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !command.contains("\u{0000}"),
              FileManager.default.fileExists(atPath: executable.path, isDirectory: &directory), !directory.boolValue,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw invalidLauncher() }
        let name = (plist["CFBundleName"] as? String) ?? bundle.deletingPathExtension().lastPathComponent
        guard validName(name) else { throw invalidLauncher() }
        return CrossOverGame(name: name, launcherPath: bundle.path, bottleName: bottleName)
    }

    /// Validate again immediately before opening, including the saved bottle association.
    public static func launchURL(for game: CrossOverGame) throws -> URL {
        try requireAvailable()
        try validateReference(game)
        let current = try self.game(at: URL(fileURLWithPath: game.launcherPath))
        guard current.bottleName == game.bottleName else {
            throw PorticoError.invalidInput(localized(
                "Середовище ярлика CrossOver змінилося. Імпортуйте гру знову.",
                "The CrossOver launcher's bottle has changed. Import the game again."))
        }
        return URL(fileURLWithPath: current.launcherPath, isDirectory: true)
    }

    /// Saving library metadata must still work when the external app is temporarily absent.
    static func validateReference(_ game: CrossOverGame) throws {
        guard validName(game.name), validName(game.bottleName), game.launcherPath.hasPrefix("/"),
              !game.launcherPath.contains("\u{0000}"),
              URL(fileURLWithPath: game.launcherPath).pathExtension.lowercased() == "app" else {
            throw invalidLauncher()
        }
    }

    static func localized(_ ukrainian: String, _ english: String) -> String {
        AppLanguage.saved() == .english ? english : ukrainian
    }

    private static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 200 && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func requireAvailable() throws {
        guard !DistributionPolicy.isAppStore else {
            throw PorticoError.runtimeUnavailable(localized(
                "Запуск через зовнішній CrossOver недоступний у профілі App Store.",
                "Launching through external CrossOver is unavailable in the App Store profile."))
        }
    }

    private static func invalidLauncher() -> PorticoError {
        .invalidInput(localized(
            "Ярлик CrossOver не знайдено або пошкоджено. Виберіть наявний застосунок Menu Helper, створений CrossOver.",
            "The CrossOver launcher is missing or invalid. Select an existing Menu Helper app created by CrossOver."))
    }
}
