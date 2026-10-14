import Foundation

public enum GameLaunchMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case steam, executable, crossOver
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .steam: return "Steam"
        case .executable: return L10n.text("Напряму через .exe")
        case .crossOver: return "CrossOver"
        }
    }
}

extension Game {
    /// Changes launch metadata only. A new Steam route is resolved from the
    /// destination prefix, never by carrying a source prefix's paths across.
    public func selectingLaunch(method: GameLaunchMethod, bottle: Bottle?, prefix: URL?,
                                appID: String, executable: String, arguments: [String],
                                directory: String?, crossOver: CrossOverGame?) throws -> Game {
        var updated = self
        updated.launchMethod = method
        if method == .crossOver {
            guard let crossOver else {
                throw PorticoError.invalidInput(L10n.text("Виберіть ярлик гри, створений CrossOver."))
            }
            _ = try CrossOverSupport.launchURL(for: crossOver)
            updated.crossOverLauncher = crossOver
            return updated
        }
        guard let bottle, bottle.status == .ready, let prefix else {
            throw PorticoError.invalidInput(L10n.text("Виберіть готове середовище."))
        }
        updated.bottleID = bottle.id
        if method == .steam {
            let id = try SteamAction.validatedAppID(appID.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let client = SteamSupport.executable(in: prefix) else {
                throw PorticoError.invalidInput(L10n.text("У вибраному середовищі не встановлено Steam."))
            }
            guard let installed = try SteamSupport.installedGames(in: prefix).first(where: { $0.id == id }) else {
                throw PorticoError.invalidInput(L10n.text("Цю гру не встановлено у вибраному середовищі Steam. Установіть її у клієнті або виберіть інше середовище."))
            }
            updated.steamAppID = id
            updated.executablePath = client.path
            updated.workingDirectory = installed.installDirectory.path
            updated.arguments = []
        } else {
            // A Steam card's stored executable is steam.exe, not its game binary.
            guard URL(fileURLWithPath: executable).lastPathComponent.lowercased() != "steam.exe" else {
                throw PorticoError.invalidInput(L10n.text("Для прямого запуску виберіть .exe самої гри, а не Steam."))
            }
            updated.executablePath = executable
            updated.arguments = arguments
            updated.workingDirectory = directory
        }
        try updated.validateLaunchConfiguration()
        return updated
    }
}
