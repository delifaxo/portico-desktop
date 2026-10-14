import Foundation

/// Identity metadata shipped next to the application's resources. The executable
/// layout is fixed by DistributionPolicy, so a manifest cannot redirect execution.
public struct BundledRuntimeManifest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let architecture: String?
    public let license: String?
    public let sourceURL: String?
    public let components: [String: String]?
    public let developmentOnly: Bool?

    public init(id: String, name: String, version: String, architecture: String? = nil,
                license: String? = nil, sourceURL: String? = nil, components: [String: String]? = nil,
                developmentOnly: Bool? = nil) {
        self.id = id; self.name = name; self.version = version; self.architecture = architecture
        self.license = license; self.sourceURL = sourceURL; self.components = components
        self.developmentOnly = developmentOnly
    }

    /// A missing manifest means this application contains no declared bundled runtime.
    /// A present but malformed manifest is an error, rather than an implicit fallback.
    public static func load(bundleURL: URL = Bundle.main.bundleURL) throws -> BundledRuntimeManifest? {
        guard bundleURL.isFileURL else {
            throw PorticoError.runtimeUnavailable(L10n.text("Застосунок має зберігатися в локальній папці."))
        }
        let file = bundleURL.appendingPathComponent("Contents/Resources/RuntimeManifest.json")
        let manager = FileManager.default
        do {
            let attributes = try manager.attributesOfItem(atPath: file.path)
            let canonical = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  canonical.count > bundle.count, canonical.starts(with: bundle) else {
                throw PorticoError.runtimeUnavailable(L10n.text("Опис вбудованого рушія розташований поза застосунком або не є звичайним файлом."))
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
        do {
            let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            guard !manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PorticoError.runtimeUnavailable(L10n.text("В описі вбудованого Wine відсутні ідентифікатор, назва або версія."))
            }
            return manifest
        } catch let error as PorticoError { throw error }
        catch {
            throw PorticoError.runtimeUnavailable(L10n.text("Не вдалося прочитати опис вбудованого Wine: \(error.localizedDescription)"))
        }
    }
}

/// Preserves a bundled runtime's identity when Portico.app is moved or copied.
/// Existing absolute references to independently installed Wine remain supported.
public enum RuntimeLocation {
    private static let prefix = "portico-bundled://"

    public static func resolve(reference: String, bundleURL: URL = Bundle.main.bundleURL) throws -> URL {
        if reference.hasPrefix(prefix) {
            let manifest = try checkedManifest(bundleURL: bundleURL)
            guard reference == prefix + manifest.id else {
                throw PorticoError.runtimeUnavailable(L10n.text("Для цього середовища потрібен інший випуск вбудованого Wine. Поточна версія застосунку не містить закріпленого рушія: \(reference)"))
            }
            return try checkedBundledExecutable(bundleURL: bundleURL)
        }
        guard reference.hasPrefix("/"), reference.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PorticoError.runtimeUnavailable(L10n.text("Посилання на Wine недійсне. Виберіть встановлений рушій або відновіть потрібну версію Portico."))
        }
        return URL(fileURLWithPath: reference).standardizedFileURL
    }

    public static func reference(for executable: URL, bundleURL: URL = Bundle.main.bundleURL) throws -> String {
        guard executable.isFileURL else {
            throw PorticoError.runtimeUnavailable(L10n.text("Виконуваний файл Wine має зберігатися на цьому Mac."))
        }
        let file = executable.standardizedFileURL
        let expected = bundledExecutable(bundleURL: bundleURL).standardizedFileURL
        if file == expected || file.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath() {
            let manifest = try checkedManifest(bundleURL: bundleURL)
            _ = try checkedBundledExecutable(bundleURL: bundleURL)
            return prefix + manifest.id
        }
        // Do not infer bundled identity from similarly named directories or old app copies.
        return file.path
    }

    private static func checkedManifest(bundleURL: URL) throws -> BundledRuntimeManifest {
        guard let manifest = try BundledRuntimeManifest.load(bundleURL: bundleURL) else {
            throw PorticoError.runtimeUnavailable(L10n.text("У застосунку відсутній опис закріпленого Wine. Установіть повну збірку Portico з потрібним рушієм."))
        }
        guard manifest.id == RuntimeCatalog.wine.id, manifest.version == RuntimeCatalog.wine.version else {
            throw PorticoError.runtimeUnavailable(L10n.text("Ідентифікатор або версія вбудованого Wine не відповідають цій збірці Portico. Рушій середовища не буде замінено автоматично."))
        }
        return manifest
    }

    private static func bundledExecutable(bundleURL: URL) -> URL {
        if bundleURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
            return DistributionPolicy.bundledWineURL
        }
        return bundleURL.appendingPathComponent("Contents/Frameworks/WineRuntime/bin/wine")
    }

    private static func checkedBundledExecutable(bundleURL: URL) throws -> URL {
        let wine = bundledExecutable(bundleURL: bundleURL)
        let runtime = wine.deletingLastPathComponent().deletingLastPathComponent()
        let resolvedWine = wine.standardizedFileURL.resolvingSymlinksInPath()
        let server = resolvedWine.deletingLastPathComponent().appendingPathComponent("wineserver")
        for file in [wine, server] {
            let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
            let attributes = try? FileManager.default.attributesOfItem(atPath: canonical.path)
            guard DistributionPolicy.containsRuntime(canonical, in: runtime, bundleDirectory: bundleURL),
                  attributes?[.type] as? FileAttributeType == .typeRegular,
                  FileManager.default.isExecutableFile(atPath: canonical.path) else {
                throw PorticoError.runtimeUnavailable(L10n.text("Закріплений Wine відсутній або пошкоджений усередині застосунку. Відновіть повну збірку Portico: \(file.path)"))
            }
        }
        guard server.resolvingSymlinksInPath().deletingLastPathComponent() == resolvedWine.deletingLastPathComponent() else {
            throw PorticoError.runtimeUnavailable(L10n.text("Вбудовані wine та wineserver мають належати до одного встановлення."))
        }
        return wine
    }
}
