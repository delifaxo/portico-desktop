import Foundation
import CryptoKit
import Darwin

public struct RuntimeRelease: Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let downloadURL: URL
    public let sha256: String
    public let downloadBytes: Int64
    /// The top-level .app directory inside the archive.
    public let archiveRoot: String
    /// A path relative to archiveRoot, for example Contents/Resources/wine/bin/wine64.
    public let executableRelativePath: String
    public let sourceURL: URL

    public init(id: String, name: String, version: String, downloadURL: URL, sha256: String,
                downloadBytes: Int64, archiveRoot: String, executableRelativePath: String, sourceURL: URL) {
        self.id = id; self.name = name; self.version = version
        self.downloadURL = downloadURL; self.sha256 = sha256; self.downloadBytes = downloadBytes
        self.archiveRoot = archiveRoot; self.executableRelativePath = executableRelativePath
        self.sourceURL = sourceURL
    }
}

public struct InstallProgress: Sendable, Equatable {
    /// downloading, verifying, extracting, assessing, or installed.
    public let stage: String
    public let fraction: Double?
    public init(stage: String, fraction: Double? = nil) { self.stage = stage; self.fraction = fraction }
}

public enum RuntimeInstallError: LocalizedError, Sendable {
    case invalidMetadata(String)
    case invalidArchive(String)
    case integrityFailed(String)
    case downloadFailed(String)
    case unsupported(String)
    case securityAssessmentFailed(appURL: URL, details: String)

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata(let detail), .invalidArchive(let detail), .integrityFailed(let detail),
             .downloadFailed(let detail), .unsupported(let detail): return detail
        case .securityAssessmentFailed(let appURL, let details):
            return L10n.text("Wine завантажено, але macOS не дозволила його запуск. Portico не вимикає Gatekeeper. Перевірте застосунок у Finder і налаштування «Приватність і безпека», потім повторіть перевірку.\n\(appURL.path)\n\(details)")
        }
    }
}

/// Downloads pinned artifacts and preserves the macOS security assessment boundary.
public actor RuntimeInstaller {
    private var activeDestinations: Set<String> = []
    public init() {}

    public func install(release: RuntimeRelease, rootURL: URL,
                        progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> URL {
        #if APP_STORE
        throw RuntimeInstallError.unsupported(L10n.text("У версії з App Store завантаження виконуваних рушіїв недоступне."))
        #else
        try Self.validateMetadata(release)
        guard rootURL.isFileURL else { throw RuntimeInstallError.invalidMetadata(L10n.text("Потрібен локальний каталог встановлення.")) }
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let runtimes = root.appendingPathComponent("Runtimes", isDirectory: true)
        try Self.ensureDirectory(runtimes)
        let destination = runtimes.appendingPathComponent(release.id, isDirectory: true)
        guard activeDestinations.insert(destination.path).inserted else { throw PorticoError.busy }
        defer { activeDestinations.remove(destination.path) }
        try Self.rejectSymlink(destination)

        if manager.fileExists(atPath: destination.path) {
            let manifestURL = destination.appendingPathComponent(".download.json")
            try Self.rejectSymlink(manifestURL)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: data),
                  manifest.matches(release) else {
                throw RuntimeInstallError.integrityFailed(L10n.text("Каталог цієї версії вже існує, але його дані не відповідають випуску. Portico не перезаписуватиме його: \(destination.path)"))
            }
            let executable = try Self.validateExtractedRuntime(at: destination, release: release)
            progress(InstallProgress(stage: "assessing"))
            try await Self.assess(destination.appendingPathComponent(release.archiveRoot, isDirectory: true))
            progress(InstallProgress(stage: "installed", fraction: 1))
            return executable
        }

        let stage = runtimes.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? manager.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("runtime.archive")
        _ = try await downloadArtifact(url: release.downloadURL, sha256: release.sha256,
                                       expectedBytes: release.downloadBytes, destination: archive, progress: progress)
        try Task.checkCancellation()
        progress(InstallProgress(stage: "extracting"))
        let listing = try await InstallerCommand.run("/usr/bin/tar", arguments: ["-tf", archive.path])
        guard listing.status == 0 else { throw RuntimeInstallError.invalidArchive(L10n.text("Не вдалося прочитати архів Wine. \(listing.output.suffix(2000))")) }
        try Self.validateArchiveEntries(listing.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                                       expectedRoot: release.archiveRoot)
        let unpacked = stage.appendingPathComponent("unpacked", isDirectory: true)
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: false)
        // bsdtar's normal path and symlink protections remain enabled; never use -P.
        let extraction = try await InstallerCommand.run("/usr/bin/tar", arguments: ["-xf", archive.path, "-C", unpacked.path, "--no-same-owner"])
        guard extraction.status == 0 else { throw RuntimeInstallError.invalidArchive(L10n.text("Не вдалося розпакувати Wine. \(extraction.output.suffix(2000))")) }
        _ = try Self.validateExtractedRuntime(at: unpacked, release: release)
        let app = unpacked.appendingPathComponent(release.archiveRoot, isDirectory: true)
        try await Self.quarantine(app)
        try Task.checkCancellation()
        let manifest = DownloadManifest(release)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: unpacked.appendingPathComponent(".download.json"), options: .atomic)
        // Stage and destination share a parent filesystem, making the final rename atomic.
        // moveItem fails if another process already installed this version; no existing version is replaced.
        try manager.moveItem(at: unpacked, to: destination)
        let installedApp = destination.appendingPathComponent(release.archiveRoot, isDirectory: true)
        progress(InstallProgress(stage: "assessing"))
        try await Self.assess(installedApp)
        let executable = try Self.validateExtractedRuntime(at: destination, release: release)
        progress(InstallProgress(stage: "installed", fraction: 1))
        return executable
        #endif
    }

    /// Downloads a dependency such as an official GStreamer .pkg. It never opens or runs it.
    public func downloadArtifact(url: URL, sha256: String, expectedBytes: Int64, destination: URL,
                                 progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> URL {
        #if APP_STORE
        throw RuntimeInstallError.unsupported(L10n.text("У версії з App Store завантаження виконуваних компонентів недоступне."))
        #else
        try Self.validateDownloadURL(url)
        try Self.validateDigestAndSize(sha256: sha256, bytes: expectedBytes)
        guard destination.isFileURL else { throw RuntimeInstallError.invalidMetadata(L10n.text("Для завантаження потрібен локальний файл призначення.")) }
        try Task.checkCancellation()
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent)
        guard activeDestinations.insert(target.path).inserted else { throw PorticoError.busy }
        defer { activeDestinations.remove(target.path) }
        try Self.rejectSymlink(target)
        if manager.fileExists(atPath: target.path) {
            progress(InstallProgress(stage: "verifying"))
            try Self.verifyArtifact(at: target, sha256: sha256, expectedBytes: expectedBytes)
            return target
        }
        let partial = target.deletingLastPathComponent().appendingPathComponent(".download-" + UUID().uuidString)
        defer { try? manager.removeItem(at: partial) }
        progress(InstallProgress(stage: "downloading", fraction: 0))
        let transfer = ArtifactTransfer(destination: partial, expectedBytes: expectedBytes, progress: progress)
        _ = try await transfer.download(url)
        try Task.checkCancellation()
        progress(InstallProgress(stage: "verifying"))
        try Self.verifyArtifact(at: partial, sha256: sha256, expectedBytes: expectedBytes)
        try await Self.quarantine(partial)
        try Task.checkCancellation()
        try manager.moveItem(at: partial, to: target)
        return target
        #endif
    }

    public nonisolated static func validateMetadata(_ release: RuntimeRelease) throws {
        let validID = !release.id.isEmpty && release.id.count <= 120 && !release.id.hasPrefix(".") &&
            !release.id.contains("..") && release.id.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
            }
        guard validID, !release.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !release.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeInstallError.invalidMetadata(L10n.text("Некоректний опис випуску Wine."))
        }
        try validateDownloadURL(release.downloadURL)
        try validateDigestAndSize(sha256: release.sha256, bytes: release.downloadBytes)
        let appParts = try safeComponents(release.archiveRoot)
        let executableParts = try safeComponents(release.executableRelativePath)
        guard appParts.count == 1, release.archiveRoot.hasSuffix(".app"),
              !release.archiveRoot.hasSuffix("/"), !release.archiveRoot.hasPrefix("./"),
              executableParts.count >= 2, ["wine", "wine64"].contains(executableParts.last ?? ""),
              executableParts.dropLast().last == "bin", release.sourceURL.scheme?.lowercased() == "https",
              release.sourceURL.host != nil, release.sourceURL.user == nil, release.sourceURL.password == nil else {
            throw RuntimeInstallError.invalidMetadata(L10n.text("У випуску Wine неправильно вказано застосунок, виконуваний файл або джерело."))
        }
    }

    public nonisolated static func validateDownloadURL(_ url: URL) throws {
        let hosts: Set<String> = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "gstreamer.freedesktop.org", "download.microsoft.com"]
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), hosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw RuntimeInstallError.downloadFailed(L10n.text("Завантаження дозволене лише через HTTPS з офіційних серверів випуску. Отримана адреса: \(url.host ?? L10n.text("без імені сервера"))"))
        }
    }

    public nonisolated static func validateArchiveEntries(_ entries: [String], expectedRoot: String) throws {
        let expected = try safeComponents(expectedRoot)
        guard expected.count == 1 else { throw RuntimeInstallError.invalidArchive(L10n.text("Неправильний кореневий каталог архіву.")) }
        var hasApp = false
        for entry in entries where !entry.isEmpty && entry != "." && entry != "./" {
            let components = try safeComponents(entry)
            guard components.first == expected.first else {
                throw RuntimeInstallError.invalidArchive(L10n.text("Архів містить файл за межами очікуваного застосунку: \(entry)"))
            }
            hasApp = true
        }
        guard hasApp else { throw RuntimeInstallError.invalidArchive(L10n.text("Архів Wine порожній або не містить очікуваного застосунку.")) }
    }

    public nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func verifyArtifact(at file: URL, sha256 expected: String, expectedBytes: Int64) throws {
        try validateDigestAndSize(sha256: expected, bytes: expectedBytes)
        try rejectSymlink(file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == expectedBytes else {
            throw RuntimeInstallError.integrityFailed(L10n.text("Розмір завантаженого файлу не відповідає випуску. Файл не буде запущено."))
        }
        guard try sha256(of: file) == expected.lowercased() else {
            throw RuntimeInstallError.integrityFailed(L10n.text("Контрольна сума SHA-256 не відповідає випуску. Файл не буде запущено."))
        }
    }

    public nonisolated static func validateExtractedRuntime(at directory: URL, release: RuntimeRelease) throws -> URL {
        try validateMetadata(release)
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        let app = base.appendingPathComponent(release.archiveRoot, isDirectory: true)
        try rejectSymlink(app)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RuntimeInstallError.invalidArchive(L10n.text("В архіві не знайдено застосунок \(release.archiveRoot)."))
        }
        let executable = app.appendingPathComponent(release.executableRelativePath)
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
        let server = resolved.deletingLastPathComponent().appendingPathComponent("wineserver")
        for file in [executable, server] {
            let canonical = file.resolvingSymlinksInPath().standardizedFileURL
            let attrs = try? FileManager.default.attributesOfItem(atPath: canonical.path)
            guard canonical.path.hasPrefix(app.path + "/"),
                  attrs?[.type] as? FileAttributeType == .typeRegular,
                  FileManager.default.isExecutableFile(atPath: canonical.path) else {
                throw RuntimeInstallError.invalidArchive(L10n.text("Усередині застосунку не знайдено коректної пари виконуваних файлів wine/wineserver: \(file.path)"))
            }
        }
        return executable
    }

    private nonisolated static func safeComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RuntimeInstallError.invalidArchive(L10n.text("Небезпечний шлях в архіві: \(path)"))
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains(".."), !components.contains(where: { $0.contains(":") }) else {
            throw RuntimeInstallError.invalidArchive(L10n.text("Шлях в архіві виходить за межі каталогу встановлення: \(path)"))
        }
        let normalized = components.filter { $0 != "." }
        guard !normalized.isEmpty else { throw RuntimeInstallError.invalidArchive(L10n.text("Порожній шлях в архіві.")) }
        return normalized
    }

    private nonisolated static func validateDigestAndSize(sha256: String, bytes: Int64) throws {
        guard sha256.count == 64, sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }),
              bytes > 0, bytes <= 8 * 1024 * 1024 * 1024 else {
            throw RuntimeInstallError.invalidMetadata(L10n.text("Для завантаження потрібні точна SHA-256 і коректний розмір випуску."))
        }
    }

    nonisolated static func rejectSymlink(_ url: URL) throws {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw RuntimeInstallError.invalidArchive(L10n.text("Каталог встановлення або файл не має бути символічним посиланням: \(url.path)"))
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }

    private nonisolated static func ensureDirectory(_ url: URL) throws {
        try rejectSymlink(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private nonisolated static func quarantine(_ url: URL) async throws {
        let value = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";Portico;" + UUID().uuidString
        let result = try await InstallerCommand.run("/usr/bin/xattr", arguments: ["-w", "com.apple.quarantine", value, url.path])
        guard result.status == 0 else {
            throw RuntimeInstallError.integrityFailed(L10n.text("Не вдалося позначити завантаження для перевірки безпеки macOS. \(result.output.suffix(1500))"))
        }
    }

    private nonisolated static func assess(_ app: URL) async throws {
        let result = try await InstallerCommand.run("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", "--verbose=2", app.path], timeout: 120)
        guard result.status == 0 else {
            throw RuntimeInstallError.securityAssessmentFailed(appURL: app, details: String(result.output.suffix(3000)))
        }
    }

    private struct DownloadManifest: Codable {
        let releaseID: String
        let version: String
        let sha256: String
        let downloadBytes: Int64
        let archiveRoot: String
        let executableRelativePath: String
        let sourceURL: String
        init(_ release: RuntimeRelease) {
            releaseID = release.id; version = release.version; sha256 = release.sha256.lowercased()
            downloadBytes = release.downloadBytes; archiveRoot = release.archiveRoot
            executableRelativePath = release.executableRelativePath; sourceURL = release.sourceURL.absoluteString
        }
        func matches(_ release: RuntimeRelease) -> Bool {
            releaseID == release.id && version == release.version && sha256 == release.sha256.lowercased() &&
                downloadBytes == release.downloadBytes && archiveRoot == release.archiveRoot &&
                executableRelativePath == release.executableRelativePath && sourceURL == release.sourceURL.absoluteString
        }
    }
}

/// URLSession owns the temporary network file; it is moved only after HTTP and size checks.
private final class ArtifactTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (InstallProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var failure: Error?
    private var downloaded: URL?
    private var cancelled = false

    init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (InstallProgress) -> Void) {
        self.destination = destination; self.expectedBytes = expectedBytes; self.progress = progress
    }

    func download(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in begin(url, continuation: continuation) }
        } onCancel: { self.cancel() }
    }

    private func begin(_ url: URL, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.httpAdditionalHeaders = ["User-Agent": "Portico/0.1", "Accept-Encoding": "identity"]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        lock.unlock()
        task.resume()
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
            guard let url = request.url else { throw RuntimeInstallError.downloadFailed(L10n.text("Сервер повернув перенаправлення без адреси.")) }
            try RuntimeInstaller.validateDownloadURL(url)
            completionHandler(request)
        } catch { fail(error); completionHandler(nil) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedBytes, totalBytesExpectedToWrite <= expectedBytes else {
            fail(RuntimeInstallError.integrityFailed(L10n.text("Сервер надіслав файл, більший за закріплений розмір випуску. Завантаження зупинено."))); return
        }
        progress(InstallProgress(stage: "downloading", fraction: Double(totalBytesWritten) / Double(expectedBytes)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200, let url = response.url else {
                throw RuntimeInstallError.downloadFailed(L10n.text("Сервер не надав файл випуску (HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0))."))
            }
            try RuntimeInstaller.validateDownloadURL(url)
            let size = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber
            guard size?.int64Value == expectedBytes else {
                throw RuntimeInstallError.integrityFailed(L10n.text("Завантаження неповне або його розмір не відповідає випуску."))
            }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); downloaded = destination; lock.unlock()
        } catch { fail(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let finalError = cancelled ? CancellationError() : (failure ?? error)
        let downloaded = downloaded
        self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let finalError { continuation?.resume(throwing: finalError) }
        else if let downloaded { continuation?.resume(returning: downloaded) }
        else { continuation?.resume(throwing: RuntimeInstallError.downloadFailed(L10n.text("Завантаження завершилося без файлу."))) }
    }
}

/// Executes only fixed macOS tools, off the main actor, with cancellation and bounded output.
final class InstallerCommand: @unchecked Sendable {
    struct Result: Sendable { let status: Int32; let output: String }
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false

    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 300) async throws -> Result {
        let command = InstallerCommand()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try command.execute(executable, arguments: arguments, timeout: timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { command.cancel() }
    }

    private func execute(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> Result {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Portico-command-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw PorticoError.storage(L10n.text("Не вдалося створити тимчасовий журнал встановлення."))
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle; process.standardError = handle
        do { try process.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        let timer = DispatchWorkItem { [weak self] in self?.cancel(timeout: true) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        process.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; let wasTimedOut = timedOut; lock.unlock()
        if wasTimedOut { throw RuntimeInstallError.downloadFailed(L10n.text("Системна перевірка або розпакування не завершилися вчасно.")) }
        if wasCancelled { throw CancellationError() }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 20 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 20 * 1024 * 1024 else { throw RuntimeInstallError.invalidArchive(L10n.text("Системний інструмент повернув завеликий список файлів.")) }
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private func cancel(timeout: Bool = false) {
        lock.lock()
        cancelled = true; if timeout { timedOut = true }
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                if self.process.isRunning { Darwin.kill(pid, SIGKILL) }
            }
        }
        lock.unlock()
    }
}
