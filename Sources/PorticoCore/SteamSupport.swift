import Foundation

public struct SteamInstalledGame: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let installDirectory: URL

    public init(id: String, name: String, installDirectory: URL) {
        self.id = id; self.name = name; self.installDirectory = installDirectory
    }
}

/// Windows Steam inside a Wine prefix. Authentication and game downloads stay in Steam.
public struct SteamSupport: Sendable {
    public static let installerURL = URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!
    static let maximumInstallerBytes = 32 * 1024 * 1024
    private static let temporaryPrefix = "Portico-Steam-"
    public init() {}

    public static func executable(in prefix: URL) -> URL? {
        steamDirectories(in: prefix).compactMap { directory in
            child("Steam.exe", in: directory, boundary: prefix.resolvingSymlinksInPath(), directory: false)
        }.first
    }

    /// Imports only completed installations. External libraries need an explicit Wine drive mapping;
    /// the default Z: mapping to the filesystem root, UNC paths, and paths escaping a drive are ignored.
    public static func installedGames(in prefix: URL) throws -> [SteamInstalledGame] {
        guard prefix.isFileURL else { throw SteamSupportError.invalidData(L10n.text("Потрібен локальний каталог середовища Steam.")) }
        let boundary = prefix.standardizedFileURL.resolvingSymlinksInPath()
        var libraries: [(URL, URL)] = steamDirectories(in: prefix).map { ($0, boundary) }
        for (steam, root) in libraries {
            guard let apps = child("steamapps", in: steam, boundary: root, directory: true),
                  let file = child("libraryfolders.vdf", in: apps, boundary: root, directory: false),
                  let object = try? readVDF(file), let folders = object.object("libraryfolders") else { continue }
            for key in folders.keys.sorted() where !key.isEmpty && key.utf8.allSatisfy({ (48...57).contains($0) }) {
                let path = folders[key]?.string ?? folders[key]?.object?.string("path")
                if let path, let mapped = windowsDirectory(path, in: boundary) { libraries.append(mapped) }
            }
        }
        var seenLibraries = Set<String>()
        var games: [String: SteamInstalledGame] = [:]
        for (library, root) in libraries where seenLibraries.insert(library.path).inserted {
            try Task.checkCancellation()
            guard let apps = child("steamapps", in: library, boundary: root, directory: true),
                  let common = child("common", in: apps, boundary: root, directory: true) else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: [.isRegularFileKey])
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation()
                let filename = file.lastPathComponent.lowercased()
                guard filename.hasPrefix("appmanifest_"), filename.hasSuffix(".acf"),
                      let fileID = appID(String(filename.dropFirst(12).dropLast(4))),
                      fileID != "228980", // Steamworks Common Redistributables is not a launchable game.
                      isContained(file, by: root),
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let document = try? readVDF(file), let manifest = document.object("AppState"),
                      let id = manifest.string("appid").flatMap(appID), id == fileID,
                      let flags = manifest.string("StateFlags").flatMap(UInt64.init),
                      flags & 4 == 4, flags & ~UInt64(4 | 64) == 0,
                      transferIsComplete(manifest, total: "BytesToDownload", completed: "BytesDownloaded"),
                      transferIsComplete(manifest, total: "BytesToStage", completed: "BytesStaged"),
                      let name = manifest.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty, name.count <= 200, name.rangeOfCharacter(from: .controlCharacters) == nil,
                      let installName = manifest.string("installdir"),
                      let components = safeComponents(installName),
                      let installation = descend(components, from: common, boundary: common), games[id] == nil else { continue }
                games[id] = SteamInstalledGame(id: id, name: name, installDirectory: installation)
            }
        }
        return games.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    public func downloadInstaller() async throws -> URL {
        try await downloadInstaller(configuration: .ephemeral)
    }

    // Configuration injection keeps transfer validation and cancellation testable without internet access.
    func downloadInstaller(configuration: URLSessionConfiguration) async throws -> URL {
        #if APP_STORE
        throw SteamSupportError.downloadFailed(L10n.text("У версії з App Store завантаження Steam недоступне."))
        #else
        try Task.checkCancellation()
        let manager = FileManager.default
        let id = UUID().uuidString
        let directory = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(Self.temporaryPrefix + id, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? manager.removeItem(at: directory) } }
        try Data(id.utf8).write(to: directory.appendingPathComponent(".portico-steam-download"), options: .withoutOverwriting)
        let destination = directory.appendingPathComponent("SteamSetup.exe")
        try await SteamInstallerTransfer(destination: destination).download(configuration: configuration)
        try Task.checkCancellation()
        try Self.validateInstaller(at: destination)
        succeeded = true
        return destination
        #endif
    }

    /// Removes only an owned download directory. Never removes a caller-supplied installer or library.
    public static func cleanupInstaller(at installer: URL) {
        let manager = FileManager.default
        let directory = installer.deletingLastPathComponent().standardizedFileURL
        let name = directory.lastPathComponent
        guard installer.isFileURL, installer.lastPathComponent == "SteamSetup.exe", name.hasPrefix(temporaryPrefix),
              let id = UUID(uuidString: String(name.dropFirst(temporaryPrefix.count))),
              directory == directory.resolvingSymlinksInPath(),
              directory.deletingLastPathComponent() == manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL,
              let marker = try? String(contentsOf: directory.appendingPathComponent(".portico-steam-download"), encoding: .utf8),
              marker == id.uuidString else { return }
        try? manager.removeItem(at: directory)
    }

    static func validateInstallerURL(_ url: URL) throws {
        let hosts: Set<String> = ["cdn.akamai.steamstatic.com", "cdn.fastly.steamstatic.com", "cdn.cloudflare.steamstatic.com"]
        guard url.scheme?.lowercased() == "https", hosts.contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw SteamSupportError.downloadFailed(L10n.text("Інсталятор Steam можна завантажувати лише через HTTPS з офіційного сервера Valve."))
        }
    }

    static func validateInstaller(at file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size >= 64, size <= maximumInstallerBytes else {
            throw SteamSupportError.invalidData(L10n.text("Завантажено порожній або завеликий інсталятор Steam."))
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 64) ?? Data()
        guard header.count == 64, header[0] == 0x4d, header[1] == 0x5a else {
            throw SteamSupportError.invalidData(L10n.text("Сервер повернув файл, який не є інсталятором Steam для Windows."))
        }
        let offset = (0..<4).reduce(UInt64(0)) { $0 | UInt64(header[60 + $1]) << ($1 * 8) }
        guard offset >= 64, offset <= UInt64(size - 4) else {
            throw SteamSupportError.invalidData(L10n.text("Заголовок інсталятора Steam для Windows пошкоджений."))
        }
        try handle.seek(toOffset: offset)
        guard try handle.read(upToCount: 4) == Data([0x50, 0x45, 0, 0]) else {
            throw SteamSupportError.invalidData(L10n.text("Заголовок інсталятора Steam для Windows пошкоджений."))
        }
    }

    private static func appID(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let id = UInt32(value), id > 0 else { return nil }
        return String(id)
    }

    private static func transferIsComplete(_ manifest: [String: SteamVDFValue], total: String, completed: String) -> Bool {
        guard let rawTotal = manifest.string(total) else { return true }
        guard let count = UInt64(rawTotal) else { return false }
        guard count > 0 else { return true }
        guard let finished = manifest.string(completed).flatMap(UInt64.init) else { return false }
        return finished >= count
    }

    private static func steamDirectories(in prefix: URL) -> [URL] {
        guard prefix.isFileURL else { return [] }
        let root = prefix.standardizedFileURL.resolvingSymlinksInPath()
        return ["Program Files (x86)", "Program Files"].compactMap {
            descend(["drive_c", $0, "Steam"], from: root, boundary: root)
        }
    }

    private static func windowsDirectory(_ path: String, in prefix: URL) -> (URL, URL)? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let bytes = Array(normalized.utf8)
        guard bytes.count >= 3, bytes[1] == 58, bytes[2] == 47,
              (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]) else { return nil }
        var relative = String(normalized.dropFirst(3))
        while relative.hasSuffix("/") { relative.removeLast() }
        guard let components = relative.isEmpty ? [] : safeComponents(relative) else { return nil }
        let drive = String(UnicodeScalar(bytes[0])).lowercased()
        let root: URL
        if drive == "c" {
            guard let c = child("drive_c", in: prefix, boundary: prefix, directory: true) else { return nil }
            root = c
        } else {
            let mapping = prefix.appendingPathComponent("dosdevices/\(drive):")
            guard (try? mapping.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { return nil }
            root = mapping.resolvingSymlinksInPath().standardizedFileURL
            // Wine normally maps Z: to /; that is not a selected Steam library drive.
            guard root.path != "/" else { return nil }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let directory = descend(components, from: root, boundary: root) else { return nil }
        return (directory, root)
    }

    private static func safeComponents(_ path: String) -> [String]? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\"),
              !path.contains(":"), !path.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components
    }

    private static func descend(_ components: [String], from directory: URL, boundary: URL) -> URL? {
        var current = directory
        for component in components {
            guard let next = child(component, in: current, boundary: boundary, directory: true) else { return nil }
            current = next
        }
        return current
    }

    private static func child(_ name: String, in parent: URL, boundary: URL, directory: Bool) -> URL? {
        let exact = parent.appendingPathComponent(name, isDirectory: directory)
        let candidate: URL
        if FileManager.default.fileExists(atPath: exact.path) { candidate = exact }
        else {
            guard let matches = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil),
                  let match = matches.sorted(by: { $0.path < $1.path }).first(where: { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            candidate = match
        }
        var isDirectory: ObjCBool = false
        guard isContained(candidate, by: boundary), FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue == directory else { return nil }
        if !directory, (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { return nil }
        return candidate.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isContained(_ url: URL, by root: URL) -> Bool {
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        let boundary = root.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == boundary || candidate.hasPrefix(boundary + "/")
    }

    private static func readVDF(_ file: URL) throws -> [String: SteamVDFValue] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let limit = 2 * 1024 * 1024
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
            throw SteamSupportError.invalidData(L10n.text("Файл бібліотеки Steam пошкоджений або завеликий."))
        }
        return try SteamVDFParser.parse(text)
    }
}

enum SteamSupportError: LocalizedError {
    case invalidData(String), downloadFailed(String)
    var errorDescription: String? {
        switch self { case .invalidData(let message), .downloadFailed(let message): return message }
    }
}

indirect enum SteamVDFValue: Equatable {
    case string(String), object([String: SteamVDFValue])
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var object: [String: SteamVDFValue]? { if case .object(let value) = self { return value }; return nil }
}

private extension Dictionary where Key == String, Value == SteamVDFValue {
    func string(_ key: String) -> String? { self[key.lowercased()]?.string }
    func object(_ key: String) -> [String: SteamVDFValue]? { self[key.lowercased()]?.object }
}

/// Valve KeyValues: quoted and bare strings, escaped quotes/backslashes, comments, and nested objects.
struct SteamVDFParser {
    private var bytes: [UInt8]
    private var position = 0
    private enum Token { case text(String), open, close }

    static func parse(_ text: String) throws -> [String: SteamVDFValue] {
        let text = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        var parser = Self(bytes: Array(text.utf8))
        return try parser.object(depth: 0)
    }

    private mutating func object(depth: Int) throws -> [String: SteamVDFValue] {
        guard depth < 64 else { throw malformed() }
        var result: [String: SteamVDFValue] = [:]
        while let token = try next() {
            if case .close = token {
                guard depth > 0 else { throw malformed() }
                return result
            }
            guard case .text(let key) = token, let value = try next(), result[key.lowercased()] == nil else { throw malformed() }
            switch value {
            case .text(let text): result[key.lowercased()] = .string(text)
            case .open: result[key.lowercased()] = .object(try object(depth: depth + 1))
            case .close: throw malformed()
            }
        }
        guard depth == 0 else { throw malformed() }
        return result
    }

    private mutating func next() throws -> Token? {
        while position < bytes.count {
            if [9, 10, 13, 32].contains(bytes[position]) { position += 1; continue }
            if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                position += 2
                while position < bytes.count && bytes[position] != 10 { position += 1 }
                continue
            }
            if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 42 {
                position += 2
                while position + 1 < bytes.count && !(bytes[position] == 42 && bytes[position + 1] == 47) { position += 1 }
                guard position + 1 < bytes.count else { throw malformed() }
                position += 2; continue
            }
            break
        }
        guard position < bytes.count else { return nil }
        let first = bytes[position]; position += 1
        if first == 123 { return .open }
        if first == 125 { return .close }
        var value: [UInt8] = []
        if first == 34 {
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                if byte == 34 { return .text(String(decoding: value, as: UTF8.self)) }
                if byte == 92 {
                    guard position < bytes.count else { throw malformed() }
                    let escaped = bytes[position]; position += 1
                    switch escaped {
                    case 34, 92: value.append(escaped)
                    case 110: value.append(10)
                    case 114: value.append(13)
                    case 116: value.append(9)
                    default: value.append(92); value.append(escaped)
                    }
                } else { value.append(byte) }
            }
            throw malformed()
        }
        value.append(first)
        while position < bytes.count && ![9, 10, 13, 32, 123, 125].contains(bytes[position]) {
            guard bytes[position] != 34 else { throw malformed() }
            value.append(bytes[position]); position += 1
        }
        return .text(String(decoding: value, as: UTF8.self))
    }

    private func malformed() -> SteamSupportError { .invalidData(L10n.text("Не вдалося прочитати формат бібліотеки Steam.")) }
}

private final class SteamInstallerTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var handle: FileHandle?
    private var bytesWritten = 0
    private var expectedBytes: Int64 = -1
    private var failure: Error?
    private var cancelled = false

    init(destination: URL) { self.destination = destination }

    func download(configuration: URLSessionConfiguration) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 600
                configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity", "User-Agent": "Portico"]
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: SteamSupport.installerURL)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }

    private func fail(_ error: Error) {
        lock.lock(); if failure == nil { failure = error }; let task = task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        do {
            guard let url = request.url else { throw SteamSupportError.downloadFailed(L10n.text("Steam повернув порожню адресу завантаження.")) }
            try SteamSupport.validateInstallerURL(url)
            completionHandler(request)
        } catch { fail(error); completionHandler(nil) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let url = response.url else {
                throw SteamSupportError.downloadFailed(L10n.text("Не вдалося завантажити Steam (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."))
            }
            try SteamSupport.validateInstallerURL(url)
            expectedBytes = response.expectedContentLength
            guard expectedBytes <= Int64(SteamSupport.maximumInstallerBytes) else {
                throw SteamSupportError.downloadFailed(L10n.text("Інсталятор Steam перевищує допустимий розмір 32 МБ."))
            }
            try Data().write(to: destination, options: .withoutOverwriting)
            handle = try FileHandle(forWritingTo: destination)
            completionHandler(.allow)
        } catch { fail(error); completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytesWritten <= SteamSupport.maximumInstallerBytes - data.count else {
            fail(SteamSupportError.downloadFailed(L10n.text("Інсталятор Steam перевищує допустимий розмір 32 МБ."))); return
        }
        do {
            guard let handle else { throw SteamSupportError.downloadFailed(L10n.text("Не вдалося зберегти інсталятор Steam.")) }
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        } catch { fail(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.close() } catch { fail(error) }
        handle = nil
        lock.lock()
        let continuation = continuation; self.continuation = nil
        var finalError: Error? = cancelled ? CancellationError() : (failure ?? error)
        if finalError == nil && (bytesWritten == 0 || (expectedBytes >= 0 && expectedBytes != Int64(bytesWritten))) {
            finalError = SteamSupportError.downloadFailed(L10n.text("Інсталятор Steam завантажено не повністю."))
        }
        self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let finalError { continuation?.resume(throwing: finalError) }
        else { continuation?.resume() }
    }
}
