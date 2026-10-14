import Foundation
import PorticoCore

@MainActor
extension AppModel {
    func runtimeDescription(for bottle: Bottle) -> String {
        if let id = bottle.graphics?.providerID {
            if let release = GraphicsRuntimeCatalog.provider(id: id) {
                return "\(release.name) · D3DMetal"
            }
            let version = LocalGraphicsRuntime.savedVersion(providerID: id,
                rootURL: store?.rootURL.appendingPathComponent("Graphics"))
            return "\(version ?? L10n.text("Локальний Wine")) · D3DMetal"
        }
        if bottle.enginePath.hasPrefix("portico-bundled://"), let manifest = try? BundledRuntimeManifest.load() {
            return "\(manifest.name) · \(manifest.version)"
        }
        return runtimes.first { $0.executableURL.path == bottle.enginePath }?.name ?? L10n.text("Зовнішній Wine")
    }
}
