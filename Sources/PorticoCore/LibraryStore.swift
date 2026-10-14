import Foundation

/// Stores the library and all managed bottle data below one application-owned directory.
public struct LibraryStore: Sendable {
    public let rootURL: URL
    public var libraryURL: URL { rootURL.appendingPathComponent("library.json", isDirectory: false) }

    public init(rootURL: URL? = nil) throws {
        let location: URL
        if let rootURL {
            guard rootURL.isFileURL else {
                throw PorticoError.storage(L10n.text("Каталог бібліотеки має бути локальною папкою."))
            }
            location = rootURL
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            location = support.appendingPathComponent("Portico", isDirectory: true)
        }
        // Resolve an explicitly chosen root once; internal paths may never redirect elsewhere.
        // Foundation fully resolves aliases such as /var only once the destination exists.
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        self.rootURL = location.standardizedFileURL.resolvingSymlinksInPath()
        try prepareDirectories()
    }

    public func load() throws -> Library {
        try prepareDirectories()
        try rejectSymbolicLink(at: libraryURL)
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return Library() }
        do {
            let data = try Data(contentsOf: libraryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            try validateSchema(decoder.decode(SchemaHeader.self, from: data).schemaVersion)
            var library = try decoder.decode(Library.self, from: data)
            try validate(library)
            // A process cannot survive an app restart as a managed creation operation.
            // Keep the original on disk until the caller explicitly saves the recovery.
            for index in library.bottles.indices where library.bottles[index].status == .creating {
                library.bottles[index].status = .failed
            }
            return library
        } catch let error as PorticoError {
            throw error
        } catch {
            throw PorticoError.storage(L10n.text("Не вдалося прочитати бібліотеку \(libraryURL.path). Файл збережено без змін. \(error.localizedDescription)"))
        }
    }

    public func save(_ library: Library) throws {
        try validate(library)
        try prepareDirectories()
        try rejectSymbolicLink(at: libraryURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(library)
            try data.write(to: libraryURL, options: .atomic)
        } catch {
            throw PorticoError.storage(L10n.text("Не вдалося зберегти бібліотеку: \(error.localizedDescription)"))
        }
    }

    public func prefixURL(for bottle: Bottle) -> URL {
        rootURL.appendingPathComponent("Bottles", isDirectory: true)
            .appendingPathComponent(bottle.id.uuidString, isDirectory: true)
    }

    public func logURL(for bottle: Bottle) -> URL {
        rootURL.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(bottle.id.uuidString + ".log", isDirectory: false)
    }

    /// Call only after the user has explicitly confirmed permanent deletion of bottle data.
    /// Removing metadata alone should use `save` instead.
    public func removeBottleData(_ bottle: Bottle) throws {
        try prepareDirectories()
        let prefix = prefixURL(for: bottle)
        let log = logURL(for: bottle)
        // Check both paths before changing either one.
        try rejectSymbolicLink(at: prefix)
        try rejectSymbolicLink(at: log)
        for url in [prefix, log] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prepareDirectories() throws {
        let manager = FileManager.default
        guard rootURL.resolvingSymlinksInPath().standardizedFileURL.path == rootURL.path else {
            throw PorticoError.storage(L10n.text("Каталог бібліотеки було перенаправлено символічним посиланням: \(rootURL.path)"))
        }
        for url in [rootURL, rootURL.appendingPathComponent("Bottles", isDirectory: true),
                    rootURL.appendingPathComponent("Logs", isDirectory: true)] {
            try rejectSymbolicLink(at: url)
            var directory: ObjCBool = false
            if manager.fileExists(atPath: url.path, isDirectory: &directory) {
                guard directory.boolValue else {
                    throw PorticoError.storage(L10n.text("Очікувалася папка: \(url.path)"))
                }
            } else {
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        // attributesOfItem uses lstat, so dangling links are rejected too.
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw PorticoError.storage(L10n.text("Шлях бібліотеки не має бути символічним посиланням: \(url.path)"))
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }

    private func validate(_ library: Library) throws {
        try validateSchema(library.schemaVersion)
        let bottleIDs = Set(library.bottles.map(\.id))
        guard bottleIDs.count == library.bottles.count else {
            throw PorticoError.storage(L10n.text("У бібліотеці повторюються ідентифікатори середовищ."))
        }
        guard Set(library.games.map(\.id)).count == library.games.count else {
            throw PorticoError.storage(L10n.text("У бібліотеці повторюються ідентифікатори ігор."))
        }
        let crossOverGames = library.crossOverGames ?? []
        guard Set(crossOverGames.map(\.id)).count == crossOverGames.count,
              Set(crossOverGames.map {
                  URL(fileURLWithPath: $0.launcherPath).standardizedFileURL.resolvingSymlinksInPath().path
              }).count == crossOverGames.count else {
            throw PorticoError.storage(CrossOverSupport.localized(
                "У бібліотеці повторюються ігри CrossOver.", "The library contains duplicate CrossOver games."))
        }
        for game in crossOverGames { try CrossOverSupport.validateReference(game) }
        for bottle in library.bottles {
            try validateName(bottle.name)
            try bottle.graphics?.validate()
        }
        for game in library.games {
            try validateName(game.name)
            if let appID = game.steamAppID { _ = try SteamAction.validatedAppID(appID) }
            if game.effectiveLaunchMethod == .steam, game.steamAppID == nil {
                throw PorticoError.invalidInput(L10n.text("Укажіть Steam App ID для запуску через Steam."))
            }
            if let launcher = game.crossOverLauncher { try CrossOverSupport.validateReference(launcher) }
            if game.effectiveLaunchMethod == .crossOver, game.crossOverLauncher == nil {
                throw PorticoError.invalidInput(L10n.text("Виберіть ярлик гри, створений CrossOver."))
            }
            guard bottleIDs.contains(game.bottleID) else {
                throw PorticoError.storage(L10n.text("Гра «\(game.name)» посилається на відсутнє середовище."))
            }
        }
    }

    private func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 200, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PorticoError.invalidInput(L10n.text("Назва має містити від 1 до 200 символів і не містити керівних символів."))
        }
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    private func validateSchema(_ version: Int) throws {
        guard version == 1 else {
            throw PorticoError.storage(L10n.text("Версія бібліотеки \(version) не підтримується. Ця версія Portico підтримує формат 1."))
        }
    }
}
