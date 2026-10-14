import Foundation

/// Gives the embedded engine its own multimedia paths without changing external Wine installations.
public enum BundledRuntimeEnvironment {
    public static func applying(to inherited: [String: String], executable: URL,
                                bundleURL: URL = Bundle.main.bundleURL,
                                cacheRoot: URL? = nil) -> [String: String] {
        guard executable.isFileURL, bundleURL.isFileURL else { return inherited }
        let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let runtime = bundle.appendingPathComponent("Contents/Frameworks/WineRuntime", isDirectory: true)
        let wine = runtime.appendingPathComponent("bin/wine")
        guard executable.standardizedFileURL.resolvingSymlinksInPath() == wine.resolvingSymlinksInPath(),
              DistributionPolicy.containsRuntime(wine, in: runtime, bundleDirectory: bundle) else { return inherited }

        let framework = bundle.appendingPathComponent("Contents/Frameworks/GStreamer.framework", isDirectory: true)
        let gstreamer = framework.appendingPathComponent("Versions/Current", isDirectory: true)
        let plugins = gstreamer.appendingPathComponent("lib/gstreamer-1.0", isDirectory: true).path
        let scanner = gstreamer.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path
        let gioModules = gstreamer.appendingPathComponent("lib/gio/modules", isDirectory: true).path

        var environment = inherited
        // Additional plugin paths take precedence over the system path. Clear both generations.
        for key in ["GST_PLUGIN_PATH", "GST_PLUGIN_PATH_1_0"] {
            environment.removeValue(forKey: key)
        }
        environment["GST_PLUGIN_SYSTEM_PATH"] = plugins
        environment["GST_PLUGIN_SYSTEM_PATH_1_0"] = plugins
        environment["GST_PLUGIN_SCANNER"] = scanner
        environment["GST_PLUGIN_SCANNER_1_0"] = scanner
        environment["GIO_EXTRA_MODULES"] = gioModules
        // EXTRA_MODULES alone leaves the directory compiled into GLib active.
        environment["GIO_MODULE_DIR"] = gioModules

        let identity = runtimeIdentity(in: bundle)
        let version = gstreamerVersion(in: gstreamer)
        let filename = "registry-gstreamer-\(version)-\(identity.architecture).bin"
        let appID = safeComponent(Bundle(url: bundle)?.bundleIdentifier, fallback: "app.portico.mac")
        let cache = registryURL(filename: filename, runtimeID: identity.id, appID: appID, cacheRoot: cacheRoot)
        environment["GST_REGISTRY"] = cache.path
        environment["GST_REGISTRY_1_0"] = cache.path
        return environment
    }

    private static func runtimeIdentity(in bundle: URL) -> (id: String, architecture: String) {
        let url = bundle.appendingPathComponent("Contents/Resources/RuntimeManifest.json")
        let data = try? Data(contentsOf: url)
        let manifest = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // The pinned macOS Wine artifact is x86_64, even when the Swift host is arm64.
        return (safeComponent(manifest?["id"] as? String, fallback: RuntimeCatalog.wine.id),
                safeComponent(manifest?["architecture"] as? String, fallback: "x86_64"))
    }

    private static func gstreamerVersion(in directory: URL) -> String {
        let url = directory.appendingPathComponent("Resources/Info.plist")
        let data = try? Data(contentsOf: url)
        let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return safeComponent(info?["CFBundleShortVersionString"] as? String, fallback: "unknown")
    }

    private static func safeComponent(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty, value != ".", value != "..", value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
              }) else { return fallback }
        return value
    }

    private static func registryURL(filename: String, runtimeID: String, appID: String, cacheRoot: URL?) -> URL {
        let fileManager = FileManager.default
        let root = cacheRoot ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let root, root.isFileURL {
            let directory = root.appendingPathComponent(appID, isDirectory: true)
                .appendingPathComponent(runtimeID, isDirectory: true)
            if makeWritableDirectory(directory) { return directory.appendingPathComponent(filename) }
        }
        // A blocked persistent cache must not restore an inherited registry from another engine.
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("PorticoRuntimeCache-" + UUID().uuidString, isDirectory: true)
        if makeWritableDirectory(temporary) { return temporary.appendingPathComponent(filename) }
        // GStreamer can scan plugins without saving its cache if the filesystem cannot accept writes.
        return fileManager.temporaryDirectory.appendingPathComponent("Portico-\(UUID().uuidString)-\(filename)")
    }

    private static func makeWritableDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
                && FileManager.default.isWritableFile(atPath: url.path)
        } catch {
            return false
        }
    }
}
