import Foundation

/// References a user-selected, complete Wine/D3DMetal installation in place.
/// Registration performs no network access, copying, patching, or quarantine changes.
public enum LocalGraphicsRuntime {
    public static let appleDownloadPage = URL(string: "https://developer.apple.com/download/all/?q=Evaluation%20environment%20for%20Windows%20games")!

    public struct Registration: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let providerID: String
        public let runtimePath: String
        public let wineVersion: String
        public let fingerprints: [String: String]
        /// nil preserves the original GPTK registration format.
        public var layout: String? = nil
    }

    static let requiredFiles: [(String, Bool)] = [
        ("bin/wine64", true), ("bin/wineserver", true),
        ("lib/wine/x86_64-windows/d3d12.dll", false),
        ("lib/wine/x86_64-windows/d3d11.dll", false),
        ("lib/wine/x86_64-windows/dxgi.dll", false),
        ("lib/external/D3DMetal.framework/D3DMetal", false),
        ("lib/external/libd3dshared.dylib", false),
        ("lib/GStreamer.framework/Versions/1.0/lib/libgstreamer-1.0.0.dylib", false),
        ("lib/GStreamer.framework/Versions/1.0/libexec/gstreamer-1.0/gst-plugin-scanner", true)
    ]

    static let wineForgeFiles: [(String, Bool)] = [
        ("bin/wine", true), ("bin/wineserver", true),
        ("lib/wine/x86_64-unix/wine", true),
        ("lib/wine/x86_64-unix/ntdll.so", false),
        ("lib/wine/x86_64-unix/winemac.so", false),
        ("lib/wine/x86_64-windows/ntdll.dll", false),
        ("lib/libgstreamer-1.0.0.dylib", false),
        ("lib/d3dmetal/external/D3DMetal.framework/D3DMetal", false),
        ("lib/d3dmetal/external/libd3dshared.dylib", false)
    ] + ["libmetalirconverter.dylib", "libdxccontainer.dylib", "libdxcompiler.dylib", "libdxilconv.dylib", "default.metallib"].map {
        ("lib/d3dmetal/external/D3DMetal.framework/Resources/\($0)", false)
    } + ["dxgi", "d3d11", "d3d12"].flatMap { name in
        [("lib/d3dmetal/wine/x86_64-windows/\(name).dll", false),
         ("lib/d3dmetal/wine/x86_64-unix/\(name).so", false)]
    }

    static func isWineForge(_ runtime: URL) -> Bool {
        FileManager.default.fileExists(atPath: runtime.appendingPathComponent("lib/d3dmetal").path)
            && FileManager.default.fileExists(atPath: runtime.appendingPathComponent("bin/wine").path)
            && !FileManager.default.fileExists(atPath: runtime.appendingPathComponent("bin/wine64").path)
    }

    public static func isLocalProvider(_ id: String) -> Bool {
        guard id.hasPrefix("local-"), let uuid = UUID(uuidString: String(id.dropFirst(6))) else { return false }
        return id == "local-" + uuid.uuidString.lowercased()
    }

    /// Read-only inspection; accepts a complete application, Wine directory, or wine64.
    static func inspect(selection: URL) throws -> URL {
        guard selection.isFileURL else { throw unavailable() }
        let chosen = selection.standardizedFileURL.resolvingSymlinksInPath()
        let runtime: URL
        if chosen.pathExtension.lowercased() == "app" {
            runtime = chosen.appendingPathComponent("Contents/Resources/wine", isDirectory: true)
        } else if ["wine64", "wine"].contains(chosen.lastPathComponent), chosen.deletingLastPathComponent().lastPathComponent == "bin" {
            runtime = chosen.deletingLastPathComponent().deletingLastPathComponent()
        } else {
            runtime = chosen
        }
        // Mounted DMGs and temporary paths cannot provide a persistent runtime.
        guard !runtime.pathComponents.starts(with: ["/", "Volumes"]),
              !runtime.path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/") else {
            throw PorticoError.runtimeUnavailable(L10n.text("Спочатку встановіть повний рушій у постійну папку на Mac. Комплект на змонтованому DMG або в тимчасовій папці підключити не можна."))
        }
        try validateFiles(in: runtime)
        return runtime
    }

    static func validateFiles(in runtime: URL) throws {
        let manager = FileManager.default
        guard runtime.isFileURL, runtime == runtime.standardizedFileURL.resolvingSymlinksInPath() else { throw unavailable() }
        for (path, executable) in isWineForge(runtime) ? wineForgeFiles : requiredFiles {
            let file = runtime.appendingPathComponent(path)
            let canonical = file.resolvingSymlinksInPath()
            let attributes = try? manager.attributesOfItem(atPath: canonical.path)
            guard canonical.pathComponents.count > runtime.pathComponents.count,
                  canonical.pathComponents.starts(with: runtime.pathComponents),
                  attributes?[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes?[.size] as? NSNumber, size.int64Value > 0,
                  !executable || manager.isExecutableFile(atPath: canonical.path),
                  !executable || canonical == file,
                  ((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o6000 == 0 else { throw unavailable() }
        }
    }

    static func snapshot(runtime: URL, version: String, id: String = "local-" + UUID().uuidString.lowercased()) throws -> Registration {
        guard isLocalProvider(id) else { throw unavailable() }
        try validateFiles(in: runtime)
        var hashes: [String: String] = [:]
        let forge = isWineForge(runtime)
        for (path, _) in forge ? wineForgeFiles : requiredFiles {
            try Task.checkCancellation()
            hashes[path] = try RuntimeInstaller.sha256(of: runtime.appendingPathComponent(path))
        }
        return Registration(schemaVersion: forge ? 2 : 1, providerID: id, runtimePath: runtime.path,
                            wineVersion: version, fingerprints: hashes, layout: forge ? "wineforge" : nil)
    }

    public static func connect(selection: URL, rootURL: URL? = nil) async throws -> Registration {
        #if APP_STORE
        throw PorticoError.runtimeUnavailable(L10n.text("Зовнішній графічний рушій недоступний у профілі App Store."))
        #else
        try Task.checkCancellation()
        let runtime = try inspect(selection: selection)
        let before = try snapshot(runtime: runtime, version: "")
        let forge = isWineForge(runtime)
        let appleDirectory = forge ? "lib/d3dmetal/external" : "lib/external"
        for (path, identifier, deep) in [
            ("\(appleDirectory)/D3DMetal.framework", "com.apple.D3DMetal", true),
            ("\(appleDirectory)/libd3dshared.dylib", "com.apple.libd3dshared", false)
        ] {
            var args = ["--verify", "--strict"]
            if deep { args.append("--deep") }
            args += ["--test-requirement", "=identifier \"\(identifier)\" and anchor apple", runtime.appendingPathComponent(path).path]
            let result = try await InstallerCommand.run("/usr/bin/codesign", arguments: args, timeout: 30)
            guard result.status == 0 else {
                throw RuntimeInstallError.integrityFailed(L10n.text("Не вдалося перевірити оригінальний підпис Apple для \(identifier). \(result.output.suffix(2500))"))
            }
        }
        let version = try await WineEngine(graphicsRoot: rootURL).probe(executable: runtime.appendingPathComponent(forge ? "bin/wine" : "bin/wine64"))
        guard !forge || version.contains("WineForge") else { throw unavailable() }
        let registration = try snapshot(runtime: runtime, version: version, id: before.providerID)
        guard before.fingerprints == registration.fingerprints else { throw changed() }
        try Task.checkCancellation()
        try save(registration, rootURL: rootURL)
        return registration
        #endif
    }

    /// Immutable registrations keep existing bottles attached to their original engine.
    static func save(_ registration: Registration, rootURL: URL?) throws {
        guard isLocalProvider(registration.providerID) else { throw unavailable() }
        let directory = try records(rootURL: rootURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let file = directory.appendingPathComponent(registration.providerID + ".json")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw PorticoError.busy }
        try JSONEncoder().encode(registration).write(to: file, options: .withoutOverwriting)
        do {
            try Data(registration.providerID.utf8).write(to: directory.appendingPathComponent("selected"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    public static func selectedProviderID(rootURL: URL? = nil) -> String? {
        guard let directory = try? records(rootURL: rootURL),
              let data = try? readBounded(directory.appendingPathComponent("selected")),
              let id = String(data: data, encoding: .utf8), isLocalProvider(id) else { return nil }
        return id
    }

    /// Display metadata only. Launching still performs the full integrity check.
    public static func savedVersion(providerID: String, rootURL: URL? = nil) -> String? {
        guard isLocalProvider(providerID),
              let directory = try? records(rootURL: rootURL),
              let data = try? readBounded(directory.appendingPathComponent(providerID + ".json")),
              let registration = try? JSONDecoder().decode(Registration.self, from: data),
              registration.providerID == providerID, !registration.wineVersion.isEmpty else { return nil }
        return registration.wineVersion
    }

    public static func resolve(providerID: String, rootURL: URL? = nil) throws -> URL {
        #if APP_STORE
        throw PorticoError.runtimeUnavailable(L10n.text("Зовнішній графічний рушій недоступний у профілі App Store."))
        #else
        guard isLocalProvider(providerID) else { throw unavailable() }
        let data = try readBounded(records(rootURL: rootURL).appendingPathComponent(providerID + ".json"))
        let saved = try JSONDecoder().decode(Registration.self, from: data)
        guard (saved.schemaVersion == 1 && saved.layout == nil || saved.schemaVersion == 2 && saved.layout == "wineforge"),
              saved.providerID == providerID, saved.runtimePath.hasPrefix("/"),
              !saved.wineVersion.isEmpty else { throw unavailable() }
        let runtime = URL(fileURLWithPath: saved.runtimePath, isDirectory: true)
        let current = try snapshot(runtime: runtime, version: saved.wineVersion, id: providerID)
        guard saved == current else { throw changed() }
        return runtime.appendingPathComponent(saved.layout == "wineforge" ? "bin/wine" : "bin/wine64")
        #endif
    }

    private static func records(rootURL: URL?) throws -> URL {
        let root = try GraphicsRuntimeLocation.rootDirectory(rootURL: rootURL).resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("LocalRuntimes", isDirectory: true)
        guard directory == directory.resolvingSymlinksInPath() else { throw unavailable() }
        return directory
    }

    private static func readBounded(_ file: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard file == file.resolvingSymlinksInPath(), attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 64 * 1024 else { throw unavailable() }
        return try Data(contentsOf: file)
    }

    private static func unavailable() -> PorticoError {
        .runtimeUnavailable(L10n.text("Потрібен повний сумісний комплект Wine + D3DMetal із wineserver та GStreamer. Виберіть встановлений застосунок або папку wine. Окрема бібліотека, DMG та вбудований Wine 11 не підходять."))
    }

    private static func changed() -> PorticoError {
        .runtimeUnavailable(L10n.text("Локальний рушій змінився після підключення. Підключіть його знову та створіть нове середовище; наявне середовище зберігає попередню версію."))
    }
}
