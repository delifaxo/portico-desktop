import Foundation

/// Configures Apple's opt-in DLSS translation for a managed D3DMetal launch.
public enum MetalFX {
    public static func isSupported(game: Game, bottle: Bottle) -> Bool {
        game.effectiveLaunchMethod != .crossOver && game.effectiveGraphicsProfile == .automatic
            && bottle.graphics?.backend == .d3dMetal
    }

    public static func applying(enabled: Bool, to inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment["D3DM_ENABLE_METALFX"] = enabled ? "1" : "0"
        return environment
    }
}
