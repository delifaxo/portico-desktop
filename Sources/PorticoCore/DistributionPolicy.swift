import Foundation

/// Separates direct distribution from the experimental App Store build profile.
/// This policy controls runtime paths; it does not establish App Store compliance.
public enum DistributionPolicy {
    public static var isAppStore: Bool {
        #if APP_STORE
        return true
        #else
        return false
        #endif
    }

    public static var bundledWineURL: URL {
        let frameworks = Bundle.main.privateFrameworksURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        return frameworks.appendingPathComponent("WineRuntime/bin/wine", isDirectory: false)
    }

    public static func permitsRuntime(at url: URL) -> Bool {
        #if APP_STORE
        return containsRuntime(url, in: bundledWineURL.deletingLastPathComponent().deletingLastPathComponent(),
                               bundleDirectory: Bundle.main.bundleURL)
        #else
        return true
        #endif
    }

    // Resolve aliases before comparing path components: a similar path prefix or
    // a symlink out of the bundle must not turn into an allowed runtime.
    static func containsRuntime(_ url: URL, in runtimeDirectory: URL, bundleDirectory: URL) -> Bool {
        guard url.isFileURL, runtimeDirectory.isFileURL, bundleDirectory.isFileURL else { return false }
        let runtime = runtimeDirectory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let bundle = bundleDirectory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return runtime.count > bundle.count && runtime.starts(with: bundle)
            && candidate.count > runtime.count && candidate.starts(with: runtime)
    }
}
