import Foundation

/// Per-launch Metal HUD configuration; never changes launchctl or global preferences.
public enum FPSCounter {
    public static func applying(enabled: Bool, to inherited: [String: String]) -> [String: String] {
        var environment = inherited
        // Explicit zero also overrides an inherited/global HUD setting when switched off.
        environment["MTL_HUD_ENABLED"] = enabled ? "1" : "0"
        return environment
    }
}
