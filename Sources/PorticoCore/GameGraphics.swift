import Foundation

public enum GameGraphicsProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, directX9
    public var id: String { rawValue }
    public var label: String {
        self == .automatic ? L10n.text("Автоматично — налаштування оточення") : "DirectX 9 · WineD3D"
    }
}

/// Graphics selection is independent of the storefront and game catalogue.
/// Wine AppDefaults keys use executable basenames, so ownership is checked per prefix.
public enum GameGraphics {
    static let overrides: [String: String] = {
        var values = ["d3d9": "builtin"]
        for version in 24...43 { values["d3dx9_\(version)"] = "native,builtin" }
        for version in 33...43 { values["d3dcompiler_\(version)"] = "native,builtin" }
        return values
    }()

    public struct Status: Sendable {
        public let executable: URL?
        public let configured: Bool
        public let needsRestore: Bool
    }

    struct Snapshot: Codable, Sendable {
        let gameID: UUID
        let executablePath: String
        /// Missing dictionary entries were absent before Portico changed them.
        let previous: [String: String]
        var complete: Bool
        var executable: URL { URL(fileURLWithPath: executablePath) }
    }

    public static func inspect(game: Game, prefix: URL) throws -> Status {
        if game.effectiveLaunchMethod == .crossOver {
            return Status(executable: nil, configured: true, needsRestore: false)
        }
        let snapshot = try readSnapshot(gameID: game.id, prefix: prefix)
        let executable = game.effectiveGraphicsProfile == .automatic
            ? (try? targetExecutable(game: game, prefix: prefix)) ?? snapshot?.executable
            : try targetExecutable(game: game, prefix: prefix)
        if let executable { try checkOwnership(executable: executable, gameID: game.id, prefix: prefix) }
        if game.effectiveGraphicsProfile == .automatic {
            return Status(executable: executable, configured: snapshot == nil, needsRestore: snapshot != nil)
        }
        let registry = prefix.appendingPathComponent("user.reg")
        let values = (try? registry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]))
        let text = values?.isRegularFile == true && values?.isSymbolicLink != true && (values?.fileSize ?? Int.max) < 16_000_000
            ? (try? String(contentsOf: registry, encoding: .utf8)) ?? "" : ""
        let matches = executable.map { hasOverrides(in: text, executable: $0) } ?? false
        return Status(executable: executable,
                      configured: snapshot?.complete == true && snapshot?.executablePath == executable?.path && matches,
                      needsRestore: false)
    }

    /// Only an unambiguous single executable is suggested. Launchers and helpers
    /// in larger games require the user to select the actual renderer executable.
    public static func targetExecutable(game: Game, prefix: URL) throws -> URL? {
        if game.effectiveLaunchMethod == .crossOver { return nil }
        if game.effectiveLaunchMethod == .executable {
            return try validatedExecutable(URL(fileURLWithPath: game.executablePath))
        }
        guard let installed = try SteamSupport.installedGames(in: prefix).first(where: { $0.id == game.steamAppID }) else { return nil }
        let root = installed.installDirectory.resolvingSymlinksInPath().standardizedFileURL
        if let path = game.graphicsExecutablePath, !path.isEmpty {
            let selected = try validatedExecutable(URL(fileURLWithPath: path))
            guard selected.path.hasPrefix(root.path + "/") else {
                throw PorticoError.invalidInput(L10n.text("Виберіть .exe в папці вибраної гри зі Steam."))
            }
            return selected
        }
        let candidates = executableCandidates(in: root)
        return candidates.count == 1 ? candidates[0] : nil
    }

    public static func executableCandidates(in directory: URL) -> [URL] {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        let ignored: Set<String> = ["_commonredist", "directx_redist", "directx", "redist", "redistributables", "installers"]
        var result: [URL] = [], count = 0
        for case let file as URL in enumerator {
            count += 1
            // Do not guess from a partial directory scan.
            if count > 6000 { return [] }
            let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values?.isDirectory == true {
                if ignored.contains(file.lastPathComponent.lowercased()) || enumerator.level > 6 { enumerator.skipDescendants() }
                continue
            }
            if file.pathExtension.lowercased() == "exe", let executable = try? validatedExecutable(file) {
                result.append(executable)
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func validatedExecutable(_ file: URL) throws -> URL {
        let name = file.lastPathComponent
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard file.isFileURL, file.path.hasPrefix("/"), file.pathExtension.lowercased() == "exe",
              name.count <= 240, !["steam.exe", "steamwebhelper.exe", "dxsetup.exe"].contains(name.lowercased()),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "\\/:*?\"<>|[]").union(.controlCharacters)) == nil,
              values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw PorticoError.invalidInput(L10n.text("Виберіть наявний .exe самої гри для налаштування графіки."))
        }
        return file.resolvingSymlinksInPath().standardizedFileURL
    }

    static func registryKey(for executable: URL) -> String {
        #"HKCU\Software\Wine\AppDefaults\"# + executable.lastPathComponent + #"\DllOverrides"#
    }

    static func hasOverrides(in registry: String, executable: URL) -> Bool {
        let header = (#"[Software\\Wine\\AppDefaults\\"# + executable.lastPathComponent + #"\\DllOverrides]"#).lowercased()
        var section = false, values: [String: String] = [:]
        for raw in registry.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("[") { section = line.hasPrefix(header); continue }
            guard section else { continue }
            for (name, value) in overrides where line == "\"\(name)\"=\"\(value)\"" { values[name] = value }
        }
        return values == overrides
    }

    /// Parses a live `reg query` result. Only string values are safe to restore.
    static func parseQuery(_ output: String) throws -> [String: String] {
        let expression = try NSRegularExpression(pattern: #"^\s+(\S+)\s+(REG_\S+)\s*(.*?)\s*$"#)
        var values: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            let string = line as NSString
            guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) else { continue }
            let name = string.substring(with: match.range(at: 1)).lowercased()
            guard overrides[name] != nil else { continue }
            guard string.substring(with: match.range(at: 2)) == "REG_SZ" else {
                throw PorticoError.invalidInput(L10n.text("Не вдалося зберегти поточні налаштування графіки. Зміни не застосовано."))
            }
            values[name] = string.substring(with: match.range(at: 3))
        }
        return values
    }

    static func snapshotDirectory(prefix: URL) throws -> URL {
        let folder = prefix.appendingPathComponent(".portico-graphics", isDirectory: true)
        try RuntimeInstaller.rejectSymlink(folder)
        return folder
    }
    static func snapshotURL(gameID: UUID, prefix: URL) throws -> URL {
        let file = try snapshotDirectory(prefix: prefix).appendingPathComponent(gameID.uuidString + ".json")
        try RuntimeInstaller.rejectSymlink(file)
        return file
    }
    static func readSnapshot(gameID: UUID, prefix: URL) throws -> Snapshot? {
        let file = try snapshotURL(gameID: gameID, prefix: prefix)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 100_000 else {
            throw PorticoError.storage(L10n.text("Не вдалося прочитати збережену конфігурацію графіки."))
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        guard snapshot.gameID == gameID,
              snapshot.executable.lastPathComponent.rangeOfCharacter(from: CharacterSet(charactersIn: "\\/:*?\"<>|[]").union(.controlCharacters)) == nil,
              snapshot.executable.pathExtension.lowercased() == "exe",
              snapshot.previous.keys.allSatisfy({ overrides[$0] != nil }),
              snapshot.previous.values.allSatisfy({ $0.count < 1024 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw PorticoError.storage(L10n.text("Не вдалося прочитати збережену конфігурацію графіки."))
        }
        return snapshot
    }
    static func writeSnapshot(_ snapshot: Snapshot, prefix: URL) throws {
        let file = try snapshotURL(gameID: snapshot.gameID, prefix: prefix)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }
    static func checkOwnership(executable: URL, gameID: UUID, prefix: URL) throws {
        let folder = try snapshotDirectory(prefix: prefix)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), id != gameID,
                  let other = try readSnapshot(gameID: id, prefix: prefix) else { continue }
            if other.executable.lastPathComponent.lowercased() == executable.lastPathComponent.lowercased() {
                throw PorticoError.invalidInput(L10n.text("У цьому середовищі вже налаштована інша гра з таким іменем .exe. Виберіть окреме середовище або поверніть для неї автоматичну графіку."))
            }
        }
    }
}
