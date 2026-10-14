import Foundation

extension Game {
    /// Checks local launch inputs when adding, editing, or starting a game.
    /// Loading a library does not require its games' disks to be connected.
    public func validateLaunchConfiguration() throws {
        if effectiveLaunchMethod == .crossOver {
            guard let crossOverLauncher else {
                throw PorticoError.invalidInput(L10n.text("Виберіть ярлик гри, створений CrossOver."))
            }
            _ = try CrossOverSupport.launchURL(for: crossOverLauncher)
            return
        }
        if effectiveLaunchMethod == .steam {
            _ = try SteamAction.validatedAppID(steamAppID ?? "")
        }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard executablePath.hasPrefix("/"), !executablePath.contains("\u{0000}"),
              URL(fileURLWithPath: executablePath).pathExtension.lowercased() == "exe",
              manager.fileExists(atPath: executablePath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw PorticoError.invalidInput(L10n.text("Виберіть наявний файл .exe з повним шляхом."))
        }

        if let workingDirectory {
            isDirectory = false
            guard workingDirectory.hasPrefix("/"), !workingDirectory.contains("\u{0000}"),
                  manager.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw PorticoError.invalidInput(L10n.text("Виберіть наявну робочу папку гри з повним шляхом."))
            }
        }

        guard !arguments.contains(where: { $0.contains("\u{0000}") }) else {
            throw PorticoError.invalidInput(L10n.text("Аргументи запуску не мають містити нульовий символ."))
        }
    }
}
