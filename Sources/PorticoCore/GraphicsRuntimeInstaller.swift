import Foundation

/// Installs the complete pinned GPTK provider without running or modifying its code.
/// The caller handles the applicable license before requesting installation.
public actor GraphicsRuntimeInstaller {
    public nonisolated static let archiveName = "game-porting-toolkit-3.0-3.tar.xz"
    public nonisolated static let licenseName = "License-GPTK3.pdf"
    public nonisolated static let licenseURL = URL(string: "https://github.com/user-attachments/files/23971305/License.pdf")!
    public nonisolated static let licenseSHA256 = "b099088947b67c1707de9b8e8f8dd5e03a4af8048451e455b9044553beeabcf8"
    public nonisolated static let licenseBytes: Int64 = 68_196

    private var activeRoots: Set<String> = []
    private let downloader = RuntimeInstaller()
    private static let appName = "Game Porting Toolkit.app"
    private static let wineRelativePath = "Contents/Resources/wine/bin/wine64"
    private static let frameworkRelativePath = "Contents/Resources/wine/lib/external/D3DMetal.framework"
    private static let helperRelativePath = "Contents/Resources/wine/lib/external/libd3dshared.dylib"

    public init() {}

    /// Diagnostic signature assessment without loading provider code. Its rejection
    /// is not a launch veto: macOS can permit a user-approved app that spctl rejects.
    /// Readiness must use WineEngine.probe through the normal OS execution path.
    public nonisolated static func assessExecution(executableURL: URL) async throws {
        #if APP_STORE
        throw RuntimeInstallError.unsupported(L10n.text("Зовнішній графічний рушій недоступний у профілі App Store."))
        #else
        try Task.checkCancellation()
        guard executableURL.isFileURL else {
            throw RuntimeInstallError.invalidMetadata(L10n.text("Потрібен локальний виконуваний файл GPTK."))
        }
        let executable = executableURL.standardizedFileURL
        let suffix = wineRelativePath.split(separator: "/").map(String.init)
        guard executable.pathComponents.suffix(suffix.count).elementsEqual(suffix) else {
            throw RuntimeInstallError.invalidArchive(L10n.text("Шлях до GPTK не відповідає повному встановленню Game Porting Toolkit.app."))
        }
        let app = suffix.reduce(executable) { parent, _ in parent.deletingLastPathComponent() }
        guard app.lastPathComponent == appName else {
            throw RuntimeInstallError.invalidArchive(L10n.text("Шлях до GPTK не відповідає повному встановленню Game Porting Toolkit.app."))
        }
        try requireDirectory(app)
        let canonicalApp = app.resolvingSymlinksInPath().standardizedFileURL
        for file in [executable, executable.deletingLastPathComponent().appendingPathComponent("wineserver")] {
            try requireRegularFile(file)
            let canonical = file.resolvingSymlinksInPath().standardizedFileURL
            let expected = canonicalApp.appendingPathComponent(wineRelativePath)
                .deletingLastPathComponent().appendingPathComponent(file.lastPathComponent)
            guard canonical == expected, FileManager.default.isExecutableFile(atPath: canonical.path) else {
                throw RuntimeInstallError.invalidArchive(L10n.text("Шлях до виконуваного файлу GPTK містить символічне посилання: \(file.path)"))
            }
        }
        let result = try await InstallerCommand.run("/usr/sbin/spctl", arguments: [
            "--assess", "--type", "execute", "--verbose=2", canonicalApp.path
        ], timeout: 30)
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw RuntimeInstallError.securityAssessmentFailed(appURL: canonicalApp,
                                                                details: String(result.output.suffix(3000)))
        }
        #endif
    }

    /// rootURL is the Graphics directory itself, not Application Support/Portico.
    /// Preseed Downloads/archiveName and Downloads/licenseName for offline installation;
    /// cached files are subject to the same exact size and SHA-256 checks as downloads.
    public func install(rootURL: URL? = nil,
                        progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> URL {
        #if APP_STORE
        throw RuntimeInstallError.unsupported(L10n.text("У версії з App Store завантаження виконуваних рушіїв недоступне."))
        #else
        try Task.checkCancellation()
        let manager = FileManager.default
        let requestedRoot = try GraphicsRuntimeLocation.rootDirectory(rootURL: rootURL)
        guard requestedRoot.isFileURL else {
            throw RuntimeInstallError.invalidMetadata(L10n.text("Потрібен локальний каталог встановлення."))
        }
        try Self.ensureDirectory(requestedRoot)
        let root = requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard activeRoots.insert(root.path).inserted else { throw PorticoError.busy }
        defer { activeRoots.remove(root.path) }
        let release = GraphicsRuntimeCatalog.appleGPTK3
        let metadata = Self.runtimeMetadata
        try RuntimeInstaller.validateMetadata(metadata)
        let destination = root.appendingPathComponent(release.id, isDirectory: true)
        try Self.rejectSymlink(destination)

        if manager.fileExists(atPath: destination.path) {
            progress(InstallProgress(stage: "verifying"))
            let receiptURL = destination.appendingPathComponent(".download.json")
            let receipt = try Self.readReceipt(at: receiptURL)
            guard receipt.matches(release) else {
                throw RuntimeInstallError.integrityFailed(L10n.text("Установлений GPTK не відповідає закріпленому випуску: \(destination.path)"))
            }
            let executable = try Self.validateExtractedProvider(at: destination)
            try Self.verifyLicense(at: destination.appendingPathComponent(Self.licenseName))
            guard try RuntimeInstaller.sha256(of: executable) == receipt.wineSHA256,
                  try RuntimeInstaller.sha256(of: executable.deletingLastPathComponent().appendingPathComponent("wineserver")) == receipt.wineserverSHA256 else {
                throw RuntimeInstallError.integrityFailed(L10n.text("Виконуваний файл Wine або wineserver в установленому GPTK змінено."))
            }
            progress(InstallProgress(stage: "assessing"))
            try await Self.verifyAppleSignatures(in: destination.appendingPathComponent(Self.appName))
            progress(InstallProgress(stage: "installed", fraction: 1))
            return executable
        }

        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try Self.ensureDirectory(downloads)
        let archive = try await downloader.downloadArtifact(
            url: release.downloadURL, sha256: release.sha256, expectedBytes: release.downloadBytes,
            destination: downloads.appendingPathComponent(Self.archiveName), progress: progress)
        let license = try await downloader.downloadArtifact(
            url: Self.licenseURL, sha256: Self.licenseSHA256, expectedBytes: Self.licenseBytes,
            destination: downloads.appendingPathComponent(Self.licenseName), progress: progress)
        try Task.checkCancellation()
        let stage = root.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? manager.removeItem(at: stage) }

        progress(InstallProgress(stage: "extracting"))
        let listing = try await InstallerCommand.run("/usr/bin/tar", arguments: ["-tf", archive.path])
        guard listing.status == 0 else {
            throw RuntimeInstallError.invalidArchive(L10n.text("Не вдалося прочитати архів GPTK. \(listing.output.suffix(2000))"))
        }
        try RuntimeInstaller.validateArchiveEntries(
            listing.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
            expectedRoot: Self.appName)
        // Keep bsdtar's default traversal/symlink protections; do not pass -P.
        let extraction = try await InstallerCommand.run("/usr/bin/tar", arguments: [
            "-xf", archive.path, "-C", stage.path, "--no-same-owner", "--no-same-permissions"
        ])
        guard extraction.status == 0 else {
            throw RuntimeInstallError.invalidArchive(L10n.text("Не вдалося розпакувати GPTK. \(extraction.output.suffix(2000))"))
        }
        let stagedExecutable = try Self.validateExtractedProvider(at: stage)
        let stagedApp = stage.appendingPathComponent(Self.appName, isDirectory: true)
        progress(InstallProgress(stage: "assessing"))
        try await Self.verifyAppleSignatures(in: stagedApp)
        try Task.checkCancellation()

        // Keep the license outside the original application and framework signatures.
        let retainedLicense = stage.appendingPathComponent(Self.licenseName)
        try manager.copyItem(at: license, to: retainedLicense)
        try Self.verifyLicense(at: retainedLicense)
        // A new extracted app must retain a macOS download security boundary even
        // when the verified archive was supplied through the offline cache.
        let quarantine = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";Portico;" + UUID().uuidString
        let marking = try await InstallerCommand.run("/usr/bin/xattr", arguments: [
            "-r", "-w", "com.apple.quarantine", quarantine, stagedApp.path
        ])
        guard marking.status == 0 else {
            throw RuntimeInstallError.integrityFailed(L10n.text("Не вдалося зберегти карантин завантаження macOS для GPTK. \(marking.output.suffix(1500))"))
        }
        try await Self.verifyAppleSignatures(in: stagedApp)
        let receipt = try Receipt(release: release, executable: stagedExecutable)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Completion is recorded only after integrity, containment, original Apple
        // signatures, license preservation and quarantine have all succeeded.
        try encoder.encode(receipt).write(to: stage.appendingPathComponent(".download.json"), options: .atomic)
        try Task.checkCancellation()
        // Both paths share the same filesystem; never replace an existing version.
        try manager.moveItem(at: stage, to: destination)
        let executable = destination.appendingPathComponent(Self.appName).appendingPathComponent(Self.wineRelativePath)
        progress(InstallProgress(stage: "installed", fraction: 1))
        return executable
        #endif
    }

    private nonisolated static var runtimeMetadata: RuntimeRelease {
        let release = GraphicsRuntimeCatalog.appleGPTK3
        return RuntimeRelease(id: release.id, name: release.name, version: release.version,
                              downloadURL: release.downloadURL, sha256: release.sha256,
                              downloadBytes: release.downloadBytes, archiveRoot: appName,
                              executableRelativePath: wineRelativePath, sourceURL: release.sourceURL)
    }

    /// File inspection only. No Wine, framework, plugin, or helper is loaded here.
    nonisolated static func validateExtractedProvider(at directory: URL) throws -> URL {
        let executable = try RuntimeInstaller.validateExtractedRuntime(at: directory, release: runtimeMetadata)
        let app = directory.appendingPathComponent(appName).standardizedFileURL.resolvingSymlinksInPath()
        try validateTreeClosure(at: app)
        // Require the original same-directory regular-file pair, not wrappers or
        // links selecting an executable from another provider.
        for binary in [executable, executable.deletingLastPathComponent().appendingPathComponent("wineserver")] {
            try requireRegularFile(binary)
            guard binary.standardizedFileURL.resolvingSymlinksInPath() == binary.standardizedFileURL else {
                throw RuntimeInstallError.invalidArchive(L10n.text("Шлях до виконуваного файлу GPTK містить символічне посилання: \(binary.path)"))
            }
        }
        let framework = app.appendingPathComponent(frameworkRelativePath)
        let helper = app.appendingPathComponent(helperRelativePath)
        try requireDirectory(framework)
        try requireRegularFile(helper)
        return executable
    }

    /// Every link must resolve to an existing object within this application.
    /// Device nodes, sockets, FIFOs, setuid and setgid payloads are not accepted.
    nonisolated static func validateTreeClosure(at app: URL) throws {
        try requireDirectory(app)
        let root = app.standardizedFileURL.resolvingSymlinksInPath()
        var enumerationError: Error?
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                            options: [], errorHandler: { _, error in
            enumerationError = error; return false
        }) else { throw RuntimeInstallError.invalidArchive(L10n.text("Не вдалося перевірити розпакований застосунок GPTK.")) }
        for case let item as URL in iterator {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory || type == .typeSymbolicLink else {
                throw RuntimeInstallError.invalidArchive(L10n.text("Архів GPTK містить непідтримуваний тип файлу: \(item.path)"))
            }
            if let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o6000 != 0 {
                throw RuntimeInstallError.invalidArchive(L10n.text("Архів GPTK містить файл із привілейованими правами: \(item.path)"))
            }
            let resolved = item.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/"),
                  FileManager.default.fileExists(atPath: resolved.path) else {
                throw RuntimeInstallError.invalidArchive(L10n.text("Архів GPTK містить пошкоджене або зовнішнє символічне посилання: \(item.path)"))
            }
        }
        if let enumerationError { throw enumerationError }
    }

    private nonisolated static func verifyAppleSignatures(in app: URL) async throws {
        let components: [(String, String, Bool)] = [
            (frameworkRelativePath, "com.apple.D3DMetal", true),
            (helperRelativePath, "com.apple.libd3dshared", false)
        ]
        for (path, identifier, deep) in components {
            var arguments = ["--verify", "--strict"]
            if deep { arguments.append("--deep") }
            // Leading '=' tells codesign to parse inline requirement text rather
            // than treating the requirement as a filename.
            arguments += ["--test-requirement", "=identifier \"\(identifier)\" and anchor apple",
                          app.appendingPathComponent(path).path]
            let result = try await InstallerCommand.run("/usr/bin/codesign", arguments: arguments, timeout: 120)
            guard result.status == 0 else {
                throw RuntimeInstallError.integrityFailed(L10n.text("Не вдалося перевірити оригінальний підпис Apple для \(identifier). \(result.output.suffix(2500))"))
            }
        }
    }

    private nonisolated static func verifyLicense(at url: URL) throws {
        try RuntimeInstaller.verifyArtifact(at: url, sha256: licenseSHA256, expectedBytes: licenseBytes)
    }

    private nonisolated static func rejectSymlink(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw RuntimeInstallError.invalidArchive(L10n.text("Каталог установлення GPTK не має бути символічним посиланням: \(url.path)"))
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }

    private nonisolated static func ensureDirectory(_ url: URL) throws {
        try rejectSymlink(url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try requireDirectory(url)
    }

    private nonisolated static func requireDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw RuntimeInstallError.invalidArchive(L10n.text("У GPTK очікувався звичайний каталог: \(url.path)"))
        }
    }

    private nonisolated static func requireRegularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw RuntimeInstallError.invalidArchive(L10n.text("У GPTK очікувався звичайний файл: \(url.path)"))
        }
    }

    private nonisolated static func readReceipt(at url: URL) throws -> Receipt {
        try requireRegularFile(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 64 * 1024 else {
            throw RuntimeInstallError.integrityFailed(L10n.text("Некоректний запис про встановлення GPTK."))
        }
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
    }

    private struct Receipt: Codable {
        let schemaVersion: Int
        let providerID: String
        let version: String
        let sourceURL: String
        let archiveURL: String
        let archiveSHA256: String
        let archiveBytes: Int64
        let archiveRoot: String
        let executableRelativePath: String
        let wineSHA256: String
        let wineserverSHA256: String
        let licenseURL: String
        let licenseSHA256: String
        let licenseBytes: Int64
        let licenseDocument: String
        let licenseNotice: String
        let appleSignaturesVerified: Bool
        let codeModified: Bool
        let executionAssessed: Bool

        init(release: GraphicsProviderRelease, executable: URL) throws {
            schemaVersion = 1; providerID = release.id; version = release.version
            sourceURL = release.sourceURL.absoluteString; archiveURL = release.downloadURL.absoluteString
            archiveSHA256 = release.sha256; archiveBytes = release.downloadBytes
            archiveRoot = GraphicsRuntimeInstaller.appName
            executableRelativePath = GraphicsRuntimeInstaller.wineRelativePath
            wineSHA256 = try RuntimeInstaller.sha256(of: executable)
            wineserverSHA256 = try RuntimeInstaller.sha256(of: executable.deletingLastPathComponent().appendingPathComponent("wineserver"))
            licenseURL = GraphicsRuntimeInstaller.licenseURL.absoluteString
            licenseSHA256 = GraphicsRuntimeInstaller.licenseSHA256
            licenseBytes = GraphicsRuntimeInstaller.licenseBytes
            licenseDocument = "Apple Game Porting Toolkit SLA EA18380, 2023-08-17"
            licenseNotice = "Apple software is subject to its separate license, including development/testing/evaluation purposes, non-commercial distribution limits and restrictions on modification. Installation is not permission for commercial redistribution or App Store release; rights to games are separate."
            appleSignaturesVerified = true; codeModified = false; executionAssessed = false
        }

        func matches(_ release: GraphicsProviderRelease) -> Bool {
            schemaVersion == 1 && providerID == release.id && version == release.version &&
                sourceURL == release.sourceURL.absoluteString && archiveURL == release.downloadURL.absoluteString &&
                archiveSHA256 == release.sha256 && archiveBytes == release.downloadBytes &&
                archiveRoot == GraphicsRuntimeInstaller.appName &&
                executableRelativePath == GraphicsRuntimeInstaller.wineRelativePath &&
                licenseURL == GraphicsRuntimeInstaller.licenseURL.absoluteString &&
                licenseSHA256 == GraphicsRuntimeInstaller.licenseSHA256 && licenseBytes == GraphicsRuntimeInstaller.licenseBytes &&
                appleSignaturesVerified && !codeModified && !executionAssessed
        }
    }
}
