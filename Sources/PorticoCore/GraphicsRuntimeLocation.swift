import Foundation

/// Stable identities select complete, separately installed graphics runtimes.
/// A provider is never overlaid onto an existing Wine installation.
public enum GraphicsRuntimeLocation {
    private static let scheme = "portico-graphics://"

    public static func rootDirectory(rootURL: URL? = nil) throws -> URL {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Portico/Graphics", isDirectory: true)
        guard let root, root.isFileURL else {
            throw PorticoError.runtimeUnavailable(L10n.text("Не знайдено локальну папку графічних рушіїв."))
        }
        return root.standardizedFileURL
    }

    public static func reference(providerID: String) throws -> String {
        guard GraphicsRuntimeCatalog.provider(id: providerID) != nil || LocalGraphicsRuntime.isLocalProvider(providerID) else {
            throw PorticoError.runtimeUnavailable(L10n.text("Невідомий випуск графічного рушія."))
        }
        return scheme + providerID
    }

    public static func isGraphicsReference(_ reference: String) -> Bool {
        reference.hasPrefix(scheme)
    }

    public static func resolve(reference: String, rootURL: URL? = nil) throws -> URL {
        #if APP_STORE
        throw PorticoError.runtimeUnavailable(L10n.text("Зовнішній графічний рушій недоступний у профілі App Store."))
        #else
        if reference.hasPrefix(scheme) {
            let id = String(reference.dropFirst(scheme.count))
            if LocalGraphicsRuntime.isLocalProvider(id) {
                return try LocalGraphicsRuntime.resolve(providerID: id, rootURL: rootURL)
            }
        }
        guard reference.hasPrefix(scheme),
              let provider = GraphicsRuntimeCatalog.provider(id: String(reference.dropFirst(scheme.count))) else {
            throw PorticoError.runtimeUnavailable(L10n.text("Посилання на графічний рушій недійсне."))
        }
        let root = try rootDirectory(rootURL: rootURL).resolvingSymlinksInPath()
        let installation = root.appendingPathComponent(provider.id, isDirectory: true)
        let receipt = try checkedReceipt(in: installation, provider: provider)
        let runtime = installation.appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine", isDirectory: true)
        let wine = runtime.appendingPathComponent("bin/wine64")
        // Canonical containment is checked against the fixed installation path, not
        // against a symlink-resolved provider directory which could escape the root.
        let expected = installation.standardizedFileURL.pathComponents
        for (path, executable) in [
            ("bin/wine64", true), ("bin/wineserver", true),
            ("lib/wine/x86_64-windows/d3d12.dll", false),
            ("lib/wine/x86_64-windows/d3d11.dll", false),
            ("lib/wine/x86_64-windows/dxgi.dll", false),
            ("lib/external/libd3dshared.dylib", false),
            ("lib/external/D3DMetal.framework/D3DMetal", false),
            ("lib/GStreamer.framework/Versions/1.0/lib/libgstreamer-1.0.0.dylib", false),
            ("lib/GStreamer.framework/Versions/1.0/libexec/gstreamer-1.0/gst-plugin-scanner", true)
        ] {
            let file = runtime.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            guard file.pathComponents.count > expected.count, file.pathComponents.starts(with: expected),
                  attributes?[.type] as? FileAttributeType == .typeRegular,
                  !executable || FileManager.default.isExecutableFile(atPath: file.path) else {
                throw PorticoError.runtimeUnavailable(L10n.text("Закріплений графічний рушій відсутній або пошкоджений. Установіть повний випуск: \(provider.name)."))
            }
        }
        let server = runtime.appendingPathComponent("bin/wineserver").resolvingSymlinksInPath()
        guard wine.resolvingSymlinksInPath().deletingLastPathComponent() == server.deletingLastPathComponent() else {
            throw PorticoError.runtimeUnavailable(L10n.text("Wine і wineserver графічного рушія мають належати до одного встановлення."))
        }
        guard try RuntimeInstaller.sha256(of: wine) == receipt.wineSHA256,
              try RuntimeInstaller.sha256(of: server) == receipt.wineserverSHA256 else {
            throw PorticoError.runtimeUnavailable(L10n.text("Файли графічного рушія змінилися після встановлення. Відновіть закріплений випуск."))
        }
        return wine
        #endif
    }

    private struct Receipt: Decodable {
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
        let appleSignaturesVerified: Bool
        let codeModified: Bool
    }

    private static func checkedReceipt(in installation: URL, provider: GraphicsProviderRelease) throws -> Receipt {
        let url = installation.appendingPathComponent(".download.json")
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard canonical.deletingLastPathComponent() == installation.standardizedFileURL,
              attributes?[.type] as? FileAttributeType == .typeRegular,
              let size = attributes?[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 64 * 1024,
              let data = try? Data(contentsOf: url), let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.schemaVersion == 1, receipt.providerID == provider.id, receipt.version == provider.version,
              receipt.sourceURL == provider.sourceURL.absoluteString, receipt.archiveURL == provider.downloadURL.absoluteString,
              receipt.archiveSHA256 == provider.sha256, receipt.archiveBytes == provider.downloadBytes,
              receipt.archiveRoot == "Game Porting Toolkit.app",
              receipt.executableRelativePath == "Contents/Resources/wine/bin/wine64",
              receipt.appleSignaturesVerified, !receipt.codeModified else {
            throw PorticoError.runtimeUnavailable(L10n.text("Не вдалося підтвердити повне встановлення закріпленого графічного рушія. Установіть його через Portico."))
        }
        return receipt
    }

    /// GPTK includes its own relocated GStreamer framework. No DYLD path override
    /// or system framework is required by the pinned package's native libraries.
    static func applyingEnvironment(to inherited: [String: String], executable: URL,
                                    providerID: String, cacheRoot: URL? = nil) -> [String: String] {
        var environment = inherited
        // An inherited overlay can replace the provider's PE/unix bridge or falsify
        // reported capabilities. The explicit provider always uses its own defaults.
        for key in Array(environment.keys) where key.hasPrefix("DYLD_") || key.hasPrefix("VKD3D_")
            || key.hasPrefix("DXVK_") || key.hasPrefix("D3DMETAL_") || key.hasPrefix("MVK_")
            || key.hasPrefix("D3DM_") || key.hasPrefix("DXMT_") || key.hasPrefix("WFDXCOMPAT_")
            || key.hasPrefix("GST_") || key.hasPrefix("GIO_") {
            environment.removeValue(forKey: key)
        }
        environment.removeValue(forKey: "WINEDLLPATH")
        environment.removeValue(forKey: "GRAPHICS_BACKEND")
        environment.removeValue(forKey: "ACTIVE_GRAPHICS_BACKEND")
        environment["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
        let runtime = executable.deletingLastPathComponent().deletingLastPathComponent()
        if LocalGraphicsRuntime.isLocalProvider(providerID), executable.lastPathComponent == "wine" {
            let layer = runtime.appendingPathComponent("lib/d3dmetal", isDirectory: true)
            environment["GRAPHICS_BACKEND"] = "d3dmetal"
            environment["D3DMETAL_RUNTIME_DIR"] = layer.path
            // WineForge otherwise auto-discovers sibling lib/wfdxcompat. This
            // profile was validated with Apple's direct backend, not that wrapper.
            environment["WFDXCOMPAT_RUNTIME_DIR"] = "/dev/null"
            environment["DYLD_LIBRARY_PATH"] = layer.appendingPathComponent("external").path + ":" + runtime.appendingPathComponent("lib").path
            environment["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;dxgi,d3d10,d3d10core,d3d11,d3d12=n,b;mscoree,mshtml=d"
            environment["GST_PLUGIN_SYSTEM_PATH_1_0"] = runtime.appendingPathComponent("lib/gstreamer-1.0").path
            environment["GST_PLUGIN_SCANNER_1_0"] = ""
            environment["GST_REGISTRY_FORK"] = "no"
            environment["LC_ALL"] = "en_US.UTF-8"
            return environment
        }
        let framework = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/GStreamer.framework/Versions/1.0", isDirectory: true)
        let plugins = framework.appendingPathComponent("lib/gstreamer-1.0", isDirectory: true).path
        let scanner = framework.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path
        let gio = framework.appendingPathComponent("lib/gio/modules", isDirectory: true).path
        environment["GST_PLUGIN_SYSTEM_PATH"] = plugins
        environment["GST_PLUGIN_SYSTEM_PATH_1_0"] = plugins
        environment["GST_PLUGIN_SCANNER"] = scanner
        environment["GST_PLUGIN_SCANNER_1_0"] = scanner
        environment["GIO_EXTRA_MODULES"] = gio
        environment["GIO_MODULE_DIR"] = gio
        let cache = (cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("app.portico.mac/\(providerID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let registry = cache.appendingPathComponent("registry-gstreamer-1.28.1.1-x86_64.bin").path
        environment["GST_REGISTRY"] = registry
        environment["GST_REGISTRY_1_0"] = registry
        return environment
    }
}
